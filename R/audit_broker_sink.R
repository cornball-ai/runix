## The AF_UNIX audit-broker client sink (audit-broker-contract.md, PROTOCOL.md).
## An unprivileged R process talks to the privileged, socket-activated broker
## daemon over a local AF_UNIX socket to obtain a SYSTEM-durable audit record it
## could not write itself. This is the ordinary R client of that daemon; the
## daemon lives in the separate `runix-audit-broker` package.
##
## The transport is a small guarded C client (src/unix_socket.c): base R cannot
## speak AF_UNIX, and off Linux it returns "unsupported" so this sink reports a
## typed `runix_broker_unavailable`. The client also AUTHENTICATES the server:
## a local socket path is spoofable, so the C layer requires the peer's
## kernel-verified uid (SO_PEERCRED) to be root before a single request byte is
## sent; the expected uid is pinned here and only an internal test seam can
## inject another value. Every transport/protocol failure is fail-closed --
## a missing socket, an untrusted peer, a timeout, a malformed response, or a
## broker error never falls back to a caller-owned sink and never reports
## system-durable audit.

## Transport status codes (must match src/unix_socket.c).
.RAB_ST_OK <- 0L
.RAB_ST_UNAVAILABLE <- 1L
.RAB_ST_TIMEOUT <- 2L
.RAB_ST_BAD_FRAME <- 3L
.RAB_ST_IO <- 4L
.RAB_ST_UNSUPPORTED <- 5L
.RAB_ST_PEER <- 6L

## Low-level framed request/response. Returns list(status = <int>, body =
## <raw|NULL>); never throws for a broker-side or transport failure.
.broker_call <- function(path, body, connect_ms = 2000L, recv_ms = 5000L,
                         send_ms = 5000L, expected_uid = 0L) {
    .Call(C_rab_broker_call, path, body, as.integer(connect_ms),
          as.integer(recv_ms), as.integer(send_ms), as.integer(expected_uid))
}

## Internal test harness only (never used by the sink): serve ONE connection on
## `path` from a forked child, optionally consuming the request frame, then --
## after `delay_ms` -- write `reply` VERBATIM (raw frame bytes, so a test
## controls every byte on the wire) and close. Linux-only, like the client.
.broker_test_serve_once <- function(path, reply = raw(0), read_first = TRUE,
                                    delay_ms = 0L) {
    .Call(C_rab_test_serve_once, path, as.raw(reply), isTRUE(read_first),
          as.integer(delay_ms))
}

## Runtime, side-effect-free availability probe wrapper (see C_rab_broker_probe).
.broker_probe <- function(path, expected_uid = 0L, connect_ms = 500L) {
    .Call(C_rab_broker_probe, path, as.integer(expected_uid),
          as.integer(connect_ms))
}

#' Is a root-authenticated audit broker reachable right now?
#'
#' A bounded, side-effect-free runtime probe: it connects to the broker socket,
#' authenticates the peer's kernel-verified uid (\code{SO_PEERCRED}) as root, and
#' closes WITHOUT sending a request, so no audit record is ever written. This is
#' the honest basis for \code{\link{system_durable_audit_available}} -- never a
#' caller Boolean, socket-existence inference, or static sink metadata.
#'
#' @param socket_path The broker's \code{AF_UNIX} socket path.
#' @param connect_ms Millisecond deadline for the connect.
#' @return One of \code{"available"} (a root peer answered),
#'   \code{"unavailable"} (no socket / refused), \code{"untrusted"} (a non-root
#'   peer), \code{"timeout"}, \code{"unsupported"} (not Linux), or
#'   \code{"error"}.
#' @examples
#' broker_available(tempfile(fileext = ".sock"))
#' @export
broker_available <- function(socket_path = "/run/runix-audit.sock",
                             connect_ms = 500L) {
    st <- .broker_probe(socket_path, 0L, connect_ms)
    switch(as.character(as.integer(st)),
           "0" = "available", "1" = "unavailable", "2" = "timeout",
           "6" = "untrusted", "5" = "unsupported", "error")
}

## Map a non-OK transport status to a typed, binding-free error code.
.broker_status_error <- function(status) {
    switch(as.character(as.integer(status)),
           "1" = "runix_broker_unavailable",  # no socket / refused
           "5" = "runix_broker_unavailable",  # the client is Linux-only
           "2" = "runix_broker_timeout",
           "3" = "runix_broker_bad_response",
           "4" = "runix_broker_io",
           "6" = "runix_broker_untrusted_peer",
           "runix_broker_error")
}

## ---- strict response validation ------------------------------------------
##
## The response is trusted local IPC from an authenticated root peer, but the
## adapter still validates it exactly (audit-broker-contract.md): a closed key
## set per shape, correct scalar types, documented value formats, and recursive
## duplicate-key rejection. yyjsonr has no duplicate-key read flag, but it
## PRESERVES duplicates as repeated names, so a recursive walk detects them;
## that behaviour is pinned by a fixture (one top-level, one nested).

.BROKER_SHAPES <- list(
    outcome_ok = c("ok", "persisted"),
    emit_ok    = c("audit_scope", "correlation_id", "ok", "persisted"),
    open_ok    = c("audit_scope", "binding", "correlation_id", "ok", "persisted"),
    error      = c("error", "message", "ok"))

## The broker's closed error-code set (PROTOCOL.md). Anything else in an error
## response is itself a malformed response.
.BROKER_ERROR_CODES <- c("bad_frame", "too_large", "bad_json",
                         "unknown_request", "schema_invalid", "unknown_intent",
                         "actor_mismatch", "rate_limited", "persist_failed",
                         "internal")

## Documented value formats: a correlation id is a 20-digit microsecond
## timestamp, a dash, and 16 hex chars; a binding is exactly 32 hex chars.
.BROKER_CID_RE <- "^[0-9]{20}-[0-9a-f]{16}$"
.BROKER_BINDING_RE <- "^[0-9a-f]{32}$"

.broker_is_str <- function(x) is.character(x) && length(x) == 1L && !is.na(x)
.broker_is_true <- function(x) is.logical(x) && length(x) == 1L && isTRUE(x)
.broker_is_bool <- function(x) is.logical(x) && length(x) == 1L && !is.na(x)

## Recursively reject any decoded object with a duplicate or empty key.
.broker_has_bad_keys <- function(x) {
    if (is.list(x)) {
        nm <- names(x)
        if (!is.null(nm) && (anyDuplicated(nm) != 0L || any(!nzchar(nm)))) {
            return(TRUE)
        }
        for (el in x) {
            if (.broker_has_bad_keys(el)) {
                return(TRUE)
            }
        }
    }
    FALSE
}

## Parse + strictly validate a response body (raw or character). Returns
## list(kind = <shape>|"invalid", fields = <parsed>, reason = <chr>).
.broker_parse_response <- function(body) {
    txt <- if (is.raw(body)) {
        tryCatch(rawToChar(body), error = function(e) NA_character_)
    } else {
        body
    }
    if (length(txt) != 1L || is.na(txt)) {
        return(list(kind = "invalid", reason = "unreadable body"))
    }
    parsed <- tryCatch(yyjsonr::read_json_str(txt), error = function(e) e)
    if (inherits(parsed, "condition")) {
        return(list(kind = "invalid", reason = "parse error"))
    }
    if (!is.list(parsed) || is.null(names(parsed))) {
        return(list(kind = "invalid", reason = "not a JSON object"))
    }
    if (.broker_has_bad_keys(parsed)) {
        return(list(kind = "invalid", reason = "duplicate or empty key"))
    }
    nm <- names(parsed)
    if (!("ok" %in% nm) || !.broker_is_bool(parsed$ok)) {
        return(list(kind = "invalid", reason = "missing or non-boolean ok"))
    }
    if (isTRUE(parsed$ok)) {
        kind <- NULL
        for (k in c("open_ok", "emit_ok", "outcome_ok")) {
            if (setequal(nm, .BROKER_SHAPES[[k]])) {
                kind <- k
                break
            }
        }
        if (is.null(kind)) {
            return(list(kind = "invalid", reason = "no exact success shape"))
        }
        if (!.broker_is_true(parsed$persisted)) {
            return(list(kind = "invalid", reason = "persisted not TRUE"))
        }
        if (kind %in% c("open_ok", "emit_ok")) {
            if (!.broker_is_str(parsed$correlation_id) ||
                !grepl(.BROKER_CID_RE, parsed$correlation_id)) {
                return(list(kind = "invalid", reason = "bad correlation_id"))
            }
            ## the broker sink is the SYSTEM sink; any other claimed scope is a
            ## malformed response, not a different flavour of success.
            if (!.broker_is_str(parsed$audit_scope) ||
                !identical(parsed$audit_scope, "system")) {
                return(list(kind = "invalid", reason = "audit_scope not system"))
            }
            if (identical(kind, "open_ok") &&
                (!.broker_is_str(parsed$binding) ||
                 !grepl(.BROKER_BINDING_RE, parsed$binding))) {
                return(list(kind = "invalid", reason = "bad binding"))
            }
        }
        return(list(kind = kind, fields = parsed))
    }
    if (!setequal(nm, .BROKER_SHAPES$error)) {
        return(list(kind = "invalid", reason = "not an exact error shape"))
    }
    if (!.broker_is_str(parsed$error) || !.broker_is_str(parsed$message)) {
        return(list(kind = "invalid", reason = "bad error/message type"))
    }
    if (!(parsed$error %in% .BROKER_ERROR_CODES)) {
        return(list(kind = "invalid", reason = "error code outside the contract"))
    }
    list(kind = "error", fields = parsed)
}

## The error code for a response that is not the expected success shape. Never
## includes the binding.
.broker_err_code <- function(v) {
    if (identical(v$kind, "error")) {
        return(as.character(v$fields$error))
    }
    if (!is.null(v$error)) {
        return(v$error)
    }
    "runix_broker_bad_response" # a valid-but-wrong shape
}

## The worker behind broker_audit_sink(). `expected_peer_uid` is the uid the
## transport requires of the server peer. It exists as an internal test seam (a
## harness runs an UNPRIVILEGED broker and injects its own uid); but the seam is
## not itself a security boundary, because `:::` is callable by anyone. So the
## system-durability CLAIM is coupled structurally to root: ONLY a sink that
## authenticates its peer as root (expected uid 0) ever stamps
## audit_scope = "system". A non-root peer -- the test transport, or any caller
## who reaches this via `:::` -- yields a sink whose receipts are scoped
## "untrusted" and can never advertise system durability, whatever the broker's
## response claims. The public constructor pins uid 0 and exposes no override.
.broker_audit_sink <- function(socket_path, connect_ms, recv_ms, send_ms,
                               expected_peer_uid = 0L) {
    force(socket_path)
    expected_peer_uid <- as.integer(expected_peer_uid)
    trusted <- identical(expected_peer_uid, 0L)
    ## the ONLY scope this sink may claim; root-peer sinks earn "system",
    ## everything else is downgraded regardless of the wire response.
    claimed_scope <- if (trusted) "system" else "untrusted"

    ## Encode + send a request; return a validated response or a typed failure.
    call <- function(req) {
        body <- tryCatch(encode_json_line(req), error = function(e) e)
        if (inherits(body, "condition")) {
            return(list(kind = "invalid", error = "runix_broker_bad_request"))
        }
        res <- .broker_call(socket_path, body, connect_ms, recv_ms, send_ms,
                            expected_peer_uid)
        if (!identical(as.integer(res$status), .RAB_ST_OK)) {
            return(list(kind = "transport",
                        error = .broker_status_error(res$status)))
        }
        v <- .broker_parse_response(res$body)
        if (identical(v$kind, "invalid")) {
            return(list(kind = "invalid", error = "runix_broker_bad_response"))
        }
        v
    }

    ## A failed call makes no scope claim at all: the record did not persist.
    fail_receipt <- function(err) {
        list(correlation_id = NA_character_, persisted = FALSE,
             audit_scope = NA_character_, binding = NA_character_, error = err)
    }

    open_intent <- function(record) {
        v <- call(list(type = "open_intent", record = record))
        if (!identical(v$kind, "open_ok")) {
            return(fail_receipt(.broker_err_code(v)))
        }
        ## the binding lives ONLY here, in the in-memory receipt, for the paired
        ## write_outcome; it is never logged or written anywhere else. The scope
        ## is this sink's earned scope, not the wire value.
        list(correlation_id = v$fields$correlation_id, persisted = TRUE,
             audit_scope = claimed_scope, binding = v$fields$binding,
             error = NULL)
    }

    write_outcome <- function(receipt, record) {
        bind <- receipt$binding
        if (is.null(bind) || length(bind) != 1L || is.na(bind) || !nzchar(bind)) {
            return(list(persisted = FALSE, error = "runix_broker_no_binding"))
        }
        v <- call(list(type = "write_outcome", binding = bind, record = record))
        if (!identical(v$kind, "outcome_ok")) {
            return(list(persisted = FALSE, error = .broker_err_code(v)))
        }
        list(persisted = TRUE, error = NULL)
    }

    emit <- function(record, phase = "preview", correlation_id = NULL) {
        ## the broker's emit is a narrow non-effect path: preview/noop only.
        ## Rejected here, locally, so a wrong phase never even reaches the
        ## wire. The broker mints ids; a caller-supplied id is ignored.
        if (!(is.character(phase) && length(phase) == 1L &&
              phase %in% c("preview", "noop"))) {
            return(fail_receipt("runix_broker_bad_phase"))
        }
        v <- call(list(type = "emit", phase = phase, record = record))
        if (!identical(v$kind, "emit_ok")) {
            return(fail_receipt(.broker_err_code(v)))
        }
        list(correlation_id = v$fields$correlation_id, persisted = TRUE,
             audit_scope = claimed_scope, binding = NULL, error = NULL)
    }

    ## The broker exposes no generic append: emit/open_intent/write_outcome are
    ## the only paths. A direct write() fails closed rather than pretend.
    write <- function(record) {
        list(persisted = FALSE, error = "runix_broker_no_generic_write")
    }

    list(open_intent = open_intent, write_outcome = write_outcome, emit = emit,
         write = write, kind = "broker", audit_scope = claimed_scope,
         durability = "fsync", socket_path = socket_path)
}

#' An AF_UNIX audit-broker client sink
#'
#' Constructs the sink that writes SYSTEM-durable audit through the privileged
#' \code{runix-audit-broker} daemon over a local \code{AF_UNIX} socket, so an
#' unprivileged mutation can obtain a record it could not write to the
#' root-owned system sink itself. It implements the same receipt lifecycle as
#' \code{\link{file_audit_sink}} (\code{open_intent}/\code{write_outcome}/
#' \code{emit}), but the broker mints correlation ids server-side and returns an
#' opaque \code{binding} carried only in the in-memory receipt. \code{emit}
#' accepts only the non-effect phases \code{"preview"}/\code{"noop"} (enforced
#' locally as well as by the broker).
#'
#' The client authenticates the server: before any request byte is sent, the
#' peer's kernel-verified uid (\code{SO_PEERCRED}) must be root, so a malicious
#' local socket cannot impersonate the broker and fake a persisted response.
#' Fail-closed throughout: a missing socket, an untrusted peer, a timeout, a
#' malformed response, or any broker error yields \code{persisted = FALSE} with
#' a typed error code and never falls back to a caller-owned sink; a failed
#' receipt claims no \code{audit_scope}. The broker is Linux-only: on Windows,
#' macOS, and other platforms every call returns
#' \code{runix_broker_unavailable}.
#'
#' @param socket_path The broker's \code{AF_UNIX} socket path (broker
#'   configuration; a client never chooses where root writes).
#' @param connect_ms Millisecond deadline for the connect.
#' @param recv_ms Millisecond deadline for reading the response.
#' @param send_ms Millisecond deadline for writing the request.
#' @return A sink implementing \code{open_intent}, \code{write_outcome},
#'   \code{emit}, plus \code{kind}/\code{audit_scope}/\code{durability}/
#'   \code{socket_path}.
#' @examples
#' # Requires a running broker; constructed here without connecting.
#' s <- broker_audit_sink("/run/runix-audit.sock")
#' s$kind
#' @export
broker_audit_sink <- function(socket_path = "/run/runix-audit.sock",
                              connect_ms = 2000L, recv_ms = 5000L,
                              send_ms = 5000L) {
    .broker_audit_sink(socket_path, connect_ms, recv_ms, send_ms,
                       expected_peer_uid = 0L)
}
