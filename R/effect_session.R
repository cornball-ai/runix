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

## Open an effect-bearing intent. Returns
## list(handle = <externalptr|NULL>, correlation_id = <chr|NA>,
##      status = <chr>, detail = <chr|NA>). status is "ok" on success; otherwise
## one of unavailable/unsupported/timeout/io/bad_response/untrusted_peer/
## bad_request/broker_error (detail carries the broker error code or the
## offending field). The receipt and binding never appear in the result.
.effect_session_open <- function(socket_path, operation, resource, plan_schema,
                                 plan_hash, connect_ms = 2000L, recv_ms = 5000L,
                                 send_ms = 5000L, expected_uid = 0L) {
    .Call(C_effect_session_open, socket_path, operation, resource,
          as.integer(plan_schema), plan_hash,
          as.integer(c(connect_ms, recv_ms, send_ms)), as.integer(expected_uid))
}

## Close the intent with the C-held outcome binding. `record` is the outcome
## record (a named list); it is encoded to a JSON object here and the binding is
## inserted in C, never crossing from R. Returns list(status = <chr>,
## detail = <chr|NA>); the binding is spent and wiped by the attempt regardless
## of the result, moving the session to closed.
.effect_session_write_outcome <- function(handle, record, connect_ms = 2000L,
                                          recv_ms = 5000L, send_ms = 5000L) {
    .Call(C_effect_session_write_outcome, handle, encode_json_line(record),
          as.integer(c(connect_ms, recv_ms, send_ms)))
}

## Inspect a handle's state. Returns list(state, owner_pid, correlation_id,
## has_receipt, has_binding) -- has_receipt/has_binding are booleans, never the
## secret values. For tests and assertions.
.effect_session_state <- function(handle) {
    .Call(C_effect_session_state, handle)
}
