## Native effect-session client (src/effect_session.c). An unprivileged mutation
## issuer opens a broker intent that mints a single-use EFFECT RECEIPT (to
## authorize the commit) and an OUTCOME BINDING (to close the durable record).
## Both are 128-bit secrets held in wipeable C heap and never returned to R: the
## open call hands back only an opaque handle, the non-secret correlation id,
## and a status. The handle is bound to the opening process and refuses reuse, a
## fork, or a restore-from-disk.
##
## These are the low-level internal shims. The pkgops issuer (a sibling package)
## drives them; the exported, object-oriented surface lands with the commit path
## and the effect-capability gate in a later change. Linux-only, like the broker
## client: elsewhere every call returns a typed "unsupported" status.

## Coerce `x` to a scalar integer, ERRORING (never silently truncating) if it is
## not a single, finite, non-NA, integer-VALUED number in optional [lo, hi].
## `as.integer(1.5)` would quietly become 1 and negotiate/commit the wrong value;
## every numeric argument that reaches a `.Call` is checked through here first.
.scalar_int <- function(x, what, lo = NULL, hi = NULL) {
    if (length(x) != 1L || !is.numeric(x) || is.na(x) || !is.finite(x) ||
        x != floor(x) || abs(x) > .Machine$integer.max) {
        stop(sprintf("`%s` must be a single integer value", what),
             call. = FALSE)
    }
    x <- as.integer(x)
    if (!is.null(lo) && x < lo) {
        stop(sprintf("`%s` must be >= %d", what, lo), call. = FALSE)
    }
    if (!is.null(hi) && x > hi) {
        stop(sprintf("`%s` must be <= %d", what, hi), call. = FALSE)
    }
    x
}

## Open an effect-bearing intent. Returns
## list(handle = <externalptr|NULL>, correlation_id = <chr|NA>,
##      status = <chr>, detail = <chr|NA>). status is "ok" on success; otherwise
## one of unavailable/unsupported/timeout/io/bad_response/untrusted_peer/
## bad_request/broker_error (detail carries the broker error code or the
## offending field). The receipt and binding never appear in the result.
## plan_schema is checked integer-valued only (0/negative are the C's
## bad_request / non-negative error, not silently truncated here).
.effect_session_open <- function(socket_path, operation, resource,
                                 plan_schema, plan_hash, connect_ms = 2000L,
                                 recv_ms = 5000L, send_ms = 5000L) {
    plan_schema <- .scalar_int(plan_schema, "plan_schema")
    deadlines <- c(.scalar_int(connect_ms, "connect_ms", lo = 0L),
                   .scalar_int(recv_ms, "recv_ms", lo = 0L),
                   .scalar_int(send_ms, "send_ms", lo = 0L))
    .Call(C_effect_session_open, socket_path, operation, resource, plan_schema,
          plan_hash, deadlines)
}

## Close the intent with the C-held outcome binding. `record` is the outcome
## record (a named list); it is encoded to a JSON object here and the binding is
## inserted in C, never crossing from R. Returns list(status = <chr>,
## detail = <chr|NA>); the binding is spent and wiped by the attempt regardless
## of the result, moving the session to closed.
.effect_session_write_outcome <- function(handle, record, connect_ms = 2000L,
    recv_ms = 5000L, send_ms = 5000L) {
    deadlines <- c(.scalar_int(connect_ms, "connect_ms", lo = 0L),
                   .scalar_int(recv_ms, "recv_ms", lo = 0L),
                   .scalar_int(send_ms, "send_ms", lo = 0L))
    .Call(C_effect_session_write_outcome, handle, encode_json_line(record),
          deadlines)
}

## Commit: deliver the C-held receipt to the verb's immutable pkexec entrypoint
## and read the strict result. Returns list(session_status, status,
## effect_issued, correlation_id, detail). session_status is "ok" when the helper
## spoke, else spawn_failed/unauthorized/effect_unknown; effect_issued is the
## helper's boolean, FALSE when the effect provably did not run, NA when it is
## genuinely unknown. The receipt is wiped the instant it is delivered.
.effect_session_commit <- function(handle, packages = character(),
                                   lock_timeout = 0L, deadline_ms = 120000L) {
    lock_timeout <- .scalar_int(lock_timeout, "lock_timeout", lo = 0L)
    deadline_ms <- .scalar_int(deadline_ms, "deadline_ms", lo = 0L)
    .Call(C_effect_session_commit, handle, as.character(packages),
          lock_timeout, deadline_ms)
}

## Inspect a handle's state. Returns list(state, owner_pid, correlation_id,
## has_receipt, has_binding) -- has_receipt/has_binding are booleans, never the
## secret values. For tests and assertions.
.effect_session_state <- function(handle) {
    .Call(C_effect_session_state, handle)
}

## TRUE only in a build carrying the compile-time fake-entrypoint seam
## (-DRUNIX_TESTING); FALSE in the production build. The commit-spawn tests key
## on this and skip when the seam is absent.
.effect_session_testing <- function() {
    .Call(C_effect_session_testing)
}

## TRUE only when the commit path is supported on this build/platform (an atomic
## child-side fd-close primitive is present). When FALSE, .effect_session_commit
## refuses fail-closed rather than risk leaking descriptors to the privileged
## helper. The coming effect-capability gate keys on this.
.effect_session_commit_supported <- function() {
    .Call(C_effect_session_commit_supported)
}
