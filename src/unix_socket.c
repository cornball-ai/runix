/*
 * AF_UNIX client transport for the runix audit broker (audit-broker-contract.md,
 * PROTOCOL.md). Base R's socketConnection() cannot speak AF_UNIX, so this is a
 * small, self-contained client: connect, send one length-framed request, read
 * one length-framed response, with absolute deadlines on connect/send/recv.
 *
 * It performs NO schema work: it enforces only the raw frame (version byte,
 * uint32 big-endian length, hard 64 KiB cap, complete read) and hands the body
 * bytes to the R layer, which does strict yyjsonr validation. Every failure is
 * reported as a typed status so the R sink can fail closed.
 *
 * Platform guard: the real client compiles only where AF_UNIX is available
 * (POSIX). On Windows / unsupported platforms the same entry point is compiled
 * and registered, but returns ST_UNSUPPORTED so package load never fails and
 * the broker capability is simply absent (the R layer maps this to a typed
 * runix_broker_unavailable and never claims system-durable audit there).
 */
#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <string.h>

/* status codes returned to R in list(status=, body=) */
#define RAB_ST_OK 0
#define RAB_ST_UNAVAILABLE 1  /* no socket / connection refused */
#define RAB_ST_TIMEOUT 2      /* a deadline passed */
#define RAB_ST_BAD_FRAME 3    /* bad version / oversize / truncated response */
#define RAB_ST_IO 4           /* socket error, or peer closed without a reply */
#define RAB_ST_UNSUPPORTED 5  /* AF_UNIX unavailable on this platform */

#define RAB_PROTO_VERSION 1
#define RAB_MAX_BODY 65536u /* 64 KiB, matching the wire protocol */

/* Build list(status=<int>, body=<raw|NULL>). */
static SEXP rab_result(int status, SEXP body) {
    SEXP out = PROTECT(allocVector(VECSXP, 2));
    SET_VECTOR_ELT(out, 0, ScalarInteger(status));
    SET_VECTOR_ELT(out, 1, body == R_NilValue ? R_NilValue : body);
    SEXP nm = PROTECT(allocVector(STRSXP, 2));
    SET_STRING_ELT(nm, 0, mkChar("status"));
    SET_STRING_ELT(nm, 1, mkChar("body"));
    setAttrib(out, R_NamesSymbol, nm);
    UNPROTECT(2);
    return out;
}

#ifndef _WIN32

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static long long rab_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Wait for `events` on fd until the absolute monotonic deadline.
 * 1 = ready, 0 = deadline passed, -1 = error. */
static int rab_wait(int fd, short events, long long deadline_ms) {
    for (;;) {
        long long rem = deadline_ms - rab_now_ms();
        if (rem <= 0) {
            return 0;
        }
        struct pollfd p;
        p.fd = fd;
        p.events = events;
        p.revents = 0;
        int r = poll(&p, 1, rem > 1000 ? 1000 : (int) rem);
        if (r < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (r == 0) {
            continue; /* re-check the absolute deadline */
        }
        return 1;
    }
}

/* 0 ok, -2 timeout, -1 io. */
static int rab_write_all(int fd, const unsigned char *buf, size_t n,
                         long long dl) {
    size_t off = 0;
    while (off < n) {
        int w = rab_wait(fd, POLLOUT, dl);
        if (w == 0) {
            return -2;
        }
        if (w < 0) {
            return -1;
        }
        ssize_t k = write(fd, buf + off, n - off);
        if (k < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            return -1;
        }
        off += (size_t) k;
    }
    return 0;
}

/* 0 ok, 1 eof before n, -2 timeout, -1 io. */
static int rab_read_all(int fd, unsigned char *buf, size_t n, long long dl) {
    size_t off = 0;
    while (off < n) {
        int w = rab_wait(fd, POLLIN, dl);
        if (w == 0) {
            return -2;
        }
        if (w < 0) {
            return -1;
        }
        ssize_t k = read(fd, buf + off, n - off);
        if (k < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;
            }
            return -1;
        }
        if (k == 0) {
            return 1;
        }
        off += (size_t) k;
    }
    return 0;
}

SEXP C_rab_broker_call(SEXP path_, SEXP body_, SEXP connect_ms_, SEXP recv_ms_,
                       SEXP send_ms_) {
    const char *path = CHAR(STRING_ELT(path_, 0));
    const char *body = CHAR(STRING_ELT(body_, 0));
    size_t blen = strlen(body);
    int connect_ms = asInteger(connect_ms_);
    int recv_ms = asInteger(recv_ms_);
    int send_ms = asInteger(send_ms_);
    if (blen > RAB_MAX_BODY) {
        return rab_result(RAB_ST_BAD_FRAME, R_NilValue);
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return rab_result(RAB_ST_IO, R_NilValue);
    }
    int fl = fcntl(fd, F_GETFL, 0);
    if (fl >= 0) {
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    }
    fcntl(fd, F_SETFD, FD_CLOEXEC);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr.sun_path) {
        close(fd);
        return rab_result(RAB_ST_IO, R_NilValue);
    }
    strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);

    long long cdl = rab_now_ms() + (connect_ms > 0 ? connect_ms : 0);
    if (connect(fd, (struct sockaddr *) &addr, sizeof addr) < 0) {
        if (errno == ENOENT || errno == ECONNREFUSED) {
            close(fd);
            return rab_result(RAB_ST_UNAVAILABLE, R_NilValue);
        }
        if (errno == EINPROGRESS) {
            int w = rab_wait(fd, POLLOUT, cdl);
            if (w == 0) {
                close(fd);
                return rab_result(RAB_ST_TIMEOUT, R_NilValue);
            }
            if (w < 0) {
                close(fd);
                return rab_result(RAB_ST_IO, R_NilValue);
            }
            int soerr = 0;
            socklen_t sl = sizeof soerr;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) < 0) {
                close(fd);
                return rab_result(RAB_ST_IO, R_NilValue);
            }
            if (soerr == ENOENT || soerr == ECONNREFUSED) {
                close(fd);
                return rab_result(RAB_ST_UNAVAILABLE, R_NilValue);
            }
            if (soerr != 0) {
                close(fd);
                return rab_result(RAB_ST_IO, R_NilValue);
            }
        } else {
            close(fd);
            return rab_result(RAB_ST_IO, R_NilValue);
        }
    }

    /* frame and send: [version][uint32 be length][body] */
    long long sdl = rab_now_ms() + (send_ms > 0 ? send_ms : 0);
    unsigned char hdr[5];
    hdr[0] = (unsigned char) RAB_PROTO_VERSION;
    hdr[1] = (unsigned char) ((blen >> 24) & 0xff);
    hdr[2] = (unsigned char) ((blen >> 16) & 0xff);
    hdr[3] = (unsigned char) ((blen >> 8) & 0xff);
    hdr[4] = (unsigned char) (blen & 0xff);
    int wr = rab_write_all(fd, hdr, 5, sdl);
    if (wr == 0 && blen > 0) {
        wr = rab_write_all(fd, (const unsigned char *) body, blen, sdl);
    }
    if (wr != 0) {
        close(fd);
        return rab_result(wr == -2 ? RAB_ST_TIMEOUT : RAB_ST_IO, R_NilValue);
    }

    /* read one framed response */
    long long rdl = rab_now_ms() + (recv_ms > 0 ? recv_ms : 0);
    unsigned char rhdr[5];
    int rr = rab_read_all(fd, rhdr, 5, rdl);
    if (rr != 0) {
        close(fd);
        /* eof before a reply (peer closed) is an IO failure, not a bad frame */
        return rab_result(rr == -2 ? RAB_ST_TIMEOUT : RAB_ST_IO, R_NilValue);
    }
    if (rhdr[0] != RAB_PROTO_VERSION) {
        close(fd);
        return rab_result(RAB_ST_BAD_FRAME, R_NilValue);
    }
    unsigned int rlen = ((unsigned int) rhdr[1] << 24) |
                        ((unsigned int) rhdr[2] << 16) |
                        ((unsigned int) rhdr[3] << 8) | (unsigned int) rhdr[4];
    if (rlen > RAB_MAX_BODY) {
        close(fd);
        return rab_result(RAB_ST_BAD_FRAME, R_NilValue);
    }
    SEXP raw = PROTECT(allocVector(RAWSXP, rlen));
    if (rlen > 0) {
        int br = rab_read_all(fd, RAW(raw), rlen, rdl);
        if (br != 0) {
            UNPROTECT(1);
            close(fd);
            return rab_result(br == -2 ? RAB_ST_TIMEOUT : RAB_ST_BAD_FRAME,
                              R_NilValue);
        }
    }
    close(fd);
    SEXP out = rab_result(RAB_ST_OK, raw);
    UNPROTECT(1);
    return out;
}

#else /* _WIN32: AF_UNIX broker not supported here */

SEXP C_rab_broker_call(SEXP path_, SEXP body_, SEXP connect_ms_, SEXP recv_ms_,
                       SEXP send_ms_) {
    (void) path_;
    (void) body_;
    (void) connect_ms_;
    (void) recv_ms_;
    (void) send_ms_;
    return rab_result(RAB_ST_UNSUPPORTED, R_NilValue);
}

#endif

static const R_CallMethodDef rab_call_methods[] = {
    /* registered as "rab_broker_call"; useDynLib(.fixes = "C_") binds it to the
     * R symbol object C_rab_broker_call. */
    {"rab_broker_call", (DL_FUNC) &C_rab_broker_call, 5},
    {NULL, NULL, 0}};

void R_init_runix(DllInfo *dll) {
    R_registerRoutines(dll, NULL, rab_call_methods, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
