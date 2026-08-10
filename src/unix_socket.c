/*
 * AF_UNIX client transport for the runix audit broker (audit-broker-contract.md,
 * PROTOCOL.md). Base R's socketConnection() cannot speak AF_UNIX, so this is a
 * small, self-contained client: connect, authenticate the SERVER peer via
 * SO_PEERCRED, send one length-framed request, read one length-framed response,
 * with absolute deadlines on connect/send/recv.
 *
 * Server-peer authentication: a local socket path is spoofable by any local
 * process, and a malicious listener could return a valid-looking `open_ok`,
 * making Runix issue a mutation under a false belief that system audit
 * persisted. So immediately after connect -- before a single request byte is
 * sent -- the peer's kernel-verified uid (SO_PEERCRED) must equal the expected
 * uid (root in production; the R layer pins it and only an internal test seam
 * can inject another value). A mismatch is a typed refusal.
 *
 * This file performs NO schema work: it enforces only the raw frame (version
 * byte, uint32 big-endian length, hard 64 KiB cap, complete read) and hands the
 * body bytes to the R layer, which does strict yyjsonr validation. Every
 * failure is reported as a typed status so the R sink can fail closed.
 *
 * Platform guard: the broker is Linux-only (SO_PEERCRED, systemd socket
 * activation), so the real client compiles ONLY under __linux__. Everywhere
 * else -- Windows, macOS, other Unix -- the same entry points are compiled and
 * registered but return ST_UNSUPPORTED, so package load never fails and the
 * broker capability is simply absent (the R layer maps this to a typed
 * runix_broker_unavailable and never claims system-durable audit there).
 */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE /* struct ucred / SO_PEERCRED */
#endif

#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>

#include <limits.h>
#include <string.h>

/* status codes returned to R in list(status=, body=) */
#define RAB_ST_OK 0
#define RAB_ST_UNAVAILABLE 1  /* no socket / connection refused */
#define RAB_ST_TIMEOUT 2      /* a deadline passed */
#define RAB_ST_BAD_FRAME 3    /* bad version / oversize / truncated response */
#define RAB_ST_IO 4           /* socket error, or peer closed without a reply */
#define RAB_ST_UNSUPPORTED 5  /* the broker client is Linux-only */
#define RAB_ST_PEER 6         /* server peer uid is not the expected uid */

#define RAB_PROTO_VERSION 1
#define RAB_MAX_BODY 65536u /* 64 KiB, matching the wire protocol */

/* ---- defensive .Call argument validation --------------------------------
 * These entry points are internal, but they must not assume only the wrapper
 * calls them: wrong types or NA would otherwise walk straight into C. */

static const char *rab_arg_string(SEXP x, const char *what) {
    if (TYPEOF(x) != STRSXP || LENGTH(x) != 1 || STRING_ELT(x, 0) == NA_STRING) {
        error("%s must be a single non-NA string", what);
    }
    return CHAR(STRING_ELT(x, 0));
}

static int rab_arg_nonneg_int(SEXP x, const char *what) {
    double v;
    if (TYPEOF(x) == INTSXP && LENGTH(x) == 1) {
        if (INTEGER(x)[0] == NA_INTEGER || INTEGER(x)[0] < 0) {
            error("%s must be a non-negative, non-NA integer", what);
        }
        return INTEGER(x)[0];
    }
    if (TYPEOF(x) == REALSXP && LENGTH(x) == 1) {
        v = REAL(x)[0];
        if (ISNAN(v) || v < 0 || v > INT_MAX) {
            error("%s must be a non-negative, non-NA integer", what);
        }
        return (int) v;
    }
    error("%s must be a single numeric value", what);
    return 0; /* unreached */
}

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

#ifdef __linux__

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* Monotonic milliseconds; -1 if the clock itself fails (treated as IO). */
static long long rab_now_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return -1;
    }
    return (long long) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* Wait for `events` on fd until the absolute monotonic deadline.
 * 1 = ready, 0 = deadline passed, -1 = error (including clock failure). */
static int rab_wait(int fd, short events, long long deadline_ms) {
    for (;;) {
        long long now = rab_now_ms();
        if (now < 0) {
            return -1;
        }
        long long rem = deadline_ms - now;
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

/* 0 ok, -2 timeout, -1 io. MSG_NOSIGNAL: a peer that closed must yield EPIPE,
 * never a SIGPIPE into the R process. */
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
        ssize_t k = send(fd, buf + off, n - off, MSG_NOSIGNAL);
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

/* 1 = peer uid matches, 0 = mismatch, -1 = cannot tell (fail closed as IO). */
static int rab_peer_uid_ok(int fd, int expected_uid) {
    struct ucred cred;
    socklen_t cl = sizeof cred;
    if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &cl) < 0 ||
        cl != sizeof cred) {
        return -1;
    }
    return cred.uid == (uid_t) expected_uid ? 1 : 0;
}

SEXP C_rab_broker_call(SEXP path_, SEXP body_, SEXP connect_ms_, SEXP recv_ms_,
                       SEXP send_ms_, SEXP expected_uid_) {
    const char *path = rab_arg_string(path_, "path");
    const char *body = rab_arg_string(body_, "body");
    int connect_ms = rab_arg_nonneg_int(connect_ms_, "connect_ms");
    int recv_ms = rab_arg_nonneg_int(recv_ms_, "recv_ms");
    int send_ms = rab_arg_nonneg_int(send_ms_, "send_ms");
    int expected_uid = rab_arg_nonneg_int(expected_uid_, "expected_uid");
    size_t blen = strlen(body);
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

    long long now = rab_now_ms();
    if (now < 0) {
        close(fd);
        return rab_result(RAB_ST_IO, R_NilValue);
    }
    long long cdl = now + connect_ms;
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

    /* Authenticate the SERVER before a single request byte is sent: an
     * unexpected peer uid never even receives the request. */
    int pk = rab_peer_uid_ok(fd, expected_uid);
    if (pk != 1) {
        close(fd);
        return rab_result(pk == 0 ? RAB_ST_PEER : RAB_ST_IO, R_NilValue);
    }

    /* frame and send: [version][uint32 be length][body] */
    now = rab_now_ms();
    if (now < 0) {
        close(fd);
        return rab_result(RAB_ST_IO, R_NilValue);
    }
    long long sdl = now + send_ms;
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
    now = rab_now_ms();
    if (now < 0) {
        close(fd);
        return rab_result(RAB_ST_IO, R_NilValue);
    }
    long long rdl = now + recv_ms;
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

/* Bounded, SIDE-EFFECT-FREE availability probe: connect, authenticate the peer
 * uid via SO_PEERCRED, and close WITHOUT sending a single byte -- so no audit
 * record is ever written by a probe. Returns a status (never inferred from
 * socket existence). This is what backs system_durable_audit_available. */
SEXP C_rab_broker_probe(SEXP path_, SEXP expected_uid_, SEXP connect_ms_) {
    const char *path = rab_arg_string(path_, "path");
    int expected_uid = rab_arg_nonneg_int(expected_uid_, "expected_uid");
    int connect_ms = rab_arg_nonneg_int(connect_ms_, "connect_ms");

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return ScalarInteger(RAB_ST_IO);
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
        return ScalarInteger(RAB_ST_IO);
    }
    strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);
    long long now = rab_now_ms();
    if (now < 0) {
        close(fd);
        return ScalarInteger(RAB_ST_IO);
    }
    long long cdl = now + connect_ms;
    if (connect(fd, (struct sockaddr *) &addr, sizeof addr) < 0) {
        if (errno == ENOENT || errno == ECONNREFUSED) {
            close(fd);
            return ScalarInteger(RAB_ST_UNAVAILABLE);
        }
        if (errno == EINPROGRESS) {
            int w = rab_wait(fd, POLLOUT, cdl);
            if (w == 0) {
                close(fd);
                return ScalarInteger(RAB_ST_TIMEOUT);
            }
            if (w < 0) {
                close(fd);
                return ScalarInteger(RAB_ST_IO);
            }
            int soerr = 0;
            socklen_t sl = sizeof soerr;
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) < 0) {
                close(fd);
                return ScalarInteger(RAB_ST_IO);
            }
            if (soerr == ENOENT || soerr == ECONNREFUSED) {
                close(fd);
                return ScalarInteger(RAB_ST_UNAVAILABLE);
            }
            if (soerr != 0) {
                close(fd);
                return ScalarInteger(RAB_ST_IO);
            }
        } else {
            close(fd);
            return ScalarInteger(RAB_ST_IO);
        }
    }
    int pk = rab_peer_uid_ok(fd, expected_uid);
    close(fd); /* no request sent: nothing is recorded */
    if (pk == 1) {
        return ScalarInteger(RAB_ST_OK);
    }
    if (pk == 0) {
        return ScalarInteger(RAB_ST_PEER);
    }
    return ScalarInteger(RAB_ST_IO);
}

/* ---- test support: serve one connection with verbatim reply bytes --------
 * Internal-only harness used (from a forked child) to exercise the client
 * against a hostile/misbehaving responder: malformed frames, semantic garbage
 * in valid frames, a silent server (deadline behaviour), and -- because the
 * fake server runs unprivileged -- the server-peer-uid refusal. `reply` is
 * written VERBATIM (raw frame bytes), so tests control every byte on the wire.
 * Not part of any public API and never used by the sink itself. */
SEXP C_rab_test_serve_once(SEXP path_, SEXP reply_, SEXP read_first_,
                           SEXP delay_ms_) {
    const char *path = rab_arg_string(path_, "path");
    if (TYPEOF(reply_) != RAWSXP) {
        error("reply must be a raw vector");
    }
    if (TYPEOF(read_first_) != LGLSXP || LENGTH(read_first_) != 1 ||
        LOGICAL(read_first_)[0] == NA_LOGICAL) {
        error("read_first must be a single non-NA logical");
    }
    int read_first = LOGICAL(read_first_)[0];
    int delay_ms = rab_arg_nonneg_int(delay_ms_, "delay_ms");

    /* Inert in production: this test-only responder does nothing unless a test
     * explicitly opts in via the environment. The symbol must ship (an R
     * package's src builds as one object), so gate the capability instead. */
    if (getenv("RUNIX_ALLOW_TEST_SERVER") == NULL) {
        return ScalarInteger(-98); /* refused: not enabled */
    }
    /* Refuse a path that already exists rather than clobber it: this server
     * only ever removes a socket IT created (owns_path below). */
    struct stat pst;
    if (lstat(path, &pst) == 0) {
        return ScalarInteger(-97); /* path exists; refuse */
    }

    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) {
        return ScalarInteger(-1);
    }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof addr.sun_path) {
        close(lfd);
        return ScalarInteger(-1);
    }
    strncpy(addr.sun_path, path, sizeof addr.sun_path - 1);
    if (bind(lfd, (struct sockaddr *) &addr, sizeof addr) != 0) {
        close(lfd);
        return ScalarInteger(-1); /* bind failed: nothing created to remove */
    }
    /* bind created the socket file; from here we own it and must remove it on
     * every exit path -- including a listen() failure. */
    if (listen(lfd, 1) != 0) {
        close(lfd);
        unlink(path);
        return ScalarInteger(-1);
    }

    long long now = rab_now_ms();
    if (now < 0) {
        close(lfd);
        unlink(path);
        return ScalarInteger(-1);
    }
    int rc = 0;
    int cfd = -1;
    if (rab_wait(lfd, POLLIN, now + 10000) == 1) {
        cfd = accept(lfd, NULL, NULL);
    }
    if (cfd < 0) {
        rc = -2; /* nobody connected */
    } else {
        int cfl = fcntl(cfd, F_GETFL, 0);
        if (cfl >= 0) {
            fcntl(cfd, F_SETFL, cfl | O_NONBLOCK);
        }
        if (read_first) {
            /* consume the request frame (header + bounded body), best-effort */
            long long rdl0 = rab_now_ms();
            if (rdl0 >= 0) {
                long long rdl = rdl0 + 2000;
                unsigned char h[5];
                if (rab_read_all(cfd, h, 5, rdl) == 0) {
                    unsigned int n = ((unsigned int) h[1] << 24) |
                                     ((unsigned int) h[2] << 16) |
                                     ((unsigned int) h[3] << 8) |
                                     (unsigned int) h[4];
                    if (n > 0 && n <= RAB_MAX_BODY) {
                        unsigned char *tmp = (unsigned char *) malloc(n);
                        if (tmp != NULL) {
                            (void) rab_read_all(cfd, tmp, n, rdl);
                            free(tmp);
                        }
                    }
                }
            }
        }
        if (delay_ms > 0) {
            struct timespec ts;
            ts.tv_sec = delay_ms / 1000;
            ts.tv_nsec = (long) (delay_ms % 1000) * 1000000L;
            nanosleep(&ts, NULL);
        }
        R_xlen_t rl = XLENGTH(reply_);
        if (rl > 0) {
            long long wdl0 = rab_now_ms();
            if (wdl0 >= 0 &&
                rab_write_all(cfd, RAW(reply_), (size_t) rl, wdl0 + 2000) != 0) {
                rc = -3;
            }
        }
        close(cfd);
    }
    close(lfd);
    unlink(path);
    return ScalarInteger(rc);
}

#else /* not __linux__: the broker client is Linux-only */

SEXP C_rab_broker_call(SEXP path_, SEXP body_, SEXP connect_ms_, SEXP recv_ms_,
                       SEXP send_ms_, SEXP expected_uid_) {
    /* validate anyway: misuse should error identically on every platform */
    (void) rab_arg_string(path_, "path");
    (void) rab_arg_string(body_, "body");
    (void) rab_arg_nonneg_int(connect_ms_, "connect_ms");
    (void) rab_arg_nonneg_int(recv_ms_, "recv_ms");
    (void) rab_arg_nonneg_int(send_ms_, "send_ms");
    (void) rab_arg_nonneg_int(expected_uid_, "expected_uid");
    return rab_result(RAB_ST_UNSUPPORTED, R_NilValue);
}

SEXP C_rab_broker_probe(SEXP path_, SEXP expected_uid_, SEXP connect_ms_) {
    (void) rab_arg_string(path_, "path");
    (void) rab_arg_nonneg_int(expected_uid_, "expected_uid");
    (void) rab_arg_nonneg_int(connect_ms_, "connect_ms");
    return ScalarInteger(RAB_ST_UNSUPPORTED);
}

SEXP C_rab_test_serve_once(SEXP path_, SEXP reply_, SEXP read_first_,
                           SEXP delay_ms_) {
    (void) path_;
    (void) reply_;
    (void) read_first_;
    (void) delay_ms_;
    return ScalarInteger(-99); /* unsupported platform */
}

#endif

static const R_CallMethodDef rab_call_methods[] = {
    /* registered without the C_ prefix; useDynLib(.fixes = "C_") binds them to
     * the R symbol objects C_rab_broker_call / C_rab_test_serve_once. */
    {"rab_broker_call", (DL_FUNC) &C_rab_broker_call, 6},
    {"rab_broker_probe", (DL_FUNC) &C_rab_broker_probe, 3},
    {"rab_test_serve_once", (DL_FUNC) &C_rab_test_serve_once, 4},
    {NULL, NULL, 0}};

void R_init_runix(DllInfo *dll) {
    R_registerRoutines(dll, NULL, rab_call_methods, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
