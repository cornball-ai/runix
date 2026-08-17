/*
 * Internal seam shared by the two C translation units of the runix common core:
 *   - unix_socket.c : the AF_UNIX audit-broker transport + generic client
 *   - effect_session.c : the native apt-effect session (receipt custody, spawn)
 *
 * The effect session reuses the transport's socket machinery (one framed
 * exchange, absolute deadlines, SO_PEERCRED server auth) rather than
 * duplicating it; these declarations are the only cross-file surface. Nothing
 * here is visible to R (registration in unix_socket.c controls that) -- it is
 * plain in-.so linkage between the two objects.
 *
 * The Linux-only functions are DEFINED only under __linux__ (the broker and the
 * effect session are both Linux-only); on other platforms neither unit's Linux
 * branch compiles, so the declarations are simply never referenced.
 */
#ifndef RUNIX_RAB_INTERNAL_H
#define RUNIX_RAB_INTERNAL_H

#include <R.h>
#include <Rinternals.h>
#include <stddef.h>

/* Transport status codes returned to R in list(status=, body=) and used
 * internally by rab_transport(). Must match R/audit_broker_sink.R. */
#define RAB_ST_OK 0
#define RAB_ST_UNAVAILABLE 1    /* no socket / connection refused */
#define RAB_ST_TIMEOUT 2        /* a deadline passed */
#define RAB_ST_BAD_FRAME 3      /* bad version / oversize / truncated response */
#define RAB_ST_IO 4             /* socket error, or peer closed without a reply */
#define RAB_ST_UNSUPPORTED 5    /* the broker client is Linux-only */
#define RAB_ST_PEER 6           /* server peer uid is not the expected uid */
#define RAB_ST_EFFECT_REFUSED 7 /* effect-bearing request on the generic path */

#define RAB_PROTO_VERSION 1
#define RAB_MAX_BODY 65536u /* 64 KiB, matching the wire protocol */

/* ---- cross-platform argument validation (defined in unix_socket.c) ------- */
const char *rab_arg_string(SEXP x, const char *what);
int rab_arg_nonneg_int(SEXP x, const char *what);

#ifdef __linux__
/* ---- Linux-only transport primitives (defined in unix_socket.c) ---------- */

/* One framed request/response over the broker socket on plain byte buffers,
 * never touching an R object. On RAB_ST_OK, *out_buf is a malloc'd buffer of
 * *out_len bytes the CALLER frees (explicit_bzero first if it may carry a
 * secret); a zero-length body yields *out_buf == NULL. See unix_socket.c. */
int rab_transport(const char *path, const unsigned char *req, size_t reqlen,
                  int connect_ms, int recv_ms, int send_ms, int expected_uid,
                  unsigned char **out_buf, size_t *out_len);

/* Monotonic milliseconds; -1 on clock failure. */
long long rab_now_ms(void);
/* Wait for `events` until the absolute deadline: 1 ready, 0 deadline, -1 err. */
int rab_wait(int fd, short events, long long deadline_ms);
/* 0 ok, -2 timeout, -1 io. */
int rab_write_all(int fd, const unsigned char *buf, size_t n, long long dl);
/* 0 ok, 1 eof before n, -2 timeout, -1 io. */
int rab_read_all(int fd, unsigned char *buf, size_t n, long long dl);
#endif /* __linux__ */

/* ---- effect-session .Call entry points (defined in effect_session.c) -----
 * Declared here so the registration table in unix_socket.c can reference them.
 * Compiled and registered on every platform (real under __linux__, a typed
 * "unsupported" stub elsewhere). */
SEXP effect_session_open(SEXP socket_path_, SEXP operation_, SEXP resource_,
                         SEXP plan_schema_, SEXP plan_hash_, SEXP deadlines_,
                         SEXP expected_uid_);
SEXP effect_session_write_outcome(SEXP handle_, SEXP record_, SEXP deadlines_);
SEXP effect_session_state(SEXP handle_);

#endif /* RUNIX_RAB_INTERNAL_H */
