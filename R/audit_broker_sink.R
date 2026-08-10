## The AF_UNIX audit-broker client sink (audit-broker-contract.md, PROTOCOL.md).
## An unprivileged R process talks to the privileged, socket-activated broker
## daemon over a local AF_UNIX socket to obtain a SYSTEM-durable audit record it
## could not write itself. This is the ordinary R client of that daemon; the
## daemon lives in the separate `runix-audit-broker` package.
##
## The transport is a small guarded C client (src/unix_socket.c): base R cannot
## speak AF_UNIX, and off Linux it returns "unsupported" so this sink reports a
## typed `runix_broker_unavailable`. Every transport/protocol failure is
## fail-closed here -- a missing socket, a timeout, a malformed response, or a
## broker error never falls back to a caller-owned sink and never reports
## system-durable audit.

## Transport status codes (must match src/unix_socket.c).
.RAB_ST_OK <- 0L
.RAB_ST_UNAVAILABLE <- 1L
.RAB_ST_TIMEOUT <- 2L
.RAB_ST_BAD_FRAME <- 3L
.RAB_ST_IO <- 4L
.RAB_ST_UNSUPPORTED <- 5L

## Low-level framed request/response. Returns list(status = <int>, body =
## <raw|NULL>); never throws for a broker-side or transport failure.
.broker_call <- function(path, body, connect_ms = 2000L, recv_ms = 5000L,
                         send_ms = 5000L) {
    .Call(C_rab_broker_call, path, body, as.integer(connect_ms),
          as.integer(recv_ms), as.integer(send_ms))
}

## Map a non-OK transport status to a typed, binding-free error code.
.broker_status_error <- function(status) {
    switch(as.character(as.integer(status)),
           "1" = "runix_broker_unavailable",  # no socket / refused
           "5" = "runix_broker_unavailable",  # unsupported platform
           "2" = "runix_broker_timeout",
           "3" = "runix_broker_bad_response",
           "4" = "runix_broker_io",
           "runix_broker_error")
}

## ---- strict response validation ------------------------------------------
##
## The response is trusted local IPC, but the adapter still validates it
## exactly (audit-broker-contract.md): a closed key set per shape, correct
## scalar types, and recursive duplicate-key rejection. yyjsonr has no
## duplicate-key read flag, but it PRESERVES duplicates as repeated names, so a
## recursive walk detects them; that behaviour is pinned by a fixture.

.BROKER_SHAPES <- list(
    outcome_ok = c("ok", "persisted"),
    emit_ok    = c("audit_scope", "correlation_id", "ok", "persisted"),
    open_ok    = c("audit_scope", "binding", "correlation_id", "ok", "persisted"),
    error      = c("error", "message", "ok"))

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
                !.broker_is_str(parsed$audit_scope)) {
                return(list(kind = "invalid", reason = "bad cid/scope type"))
            }
            if (identical(kind, "open_ok") && !.broker_is_str(parsed$binding)) {
                return(list(kind = "invalid", reason = "bad binding type"))
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

#' An AF_UNIX audit-broker client sink
#'
#' Constructs the sink that writes SYSTEM-durable audit through the privileged
#' \code{runix-audit-broker} daemon over a local \code{AF_UNIX} socket, so an
#' unprivileged mutation can obtain a record it could not write to the
#' root-owned system sink itself. It implements the same receipt lifecycle as
#' \code{\link{file_audit_sink}} (\code{open_intent}/\code{write_outcome}/
#' \code{emit}), but the broker mints correlation ids server-side and returns an
#' opaque \code{binding} carried only in the in-memory receipt.
#'
#' Fail-closed throughout: a missing socket, timeout, malformed response, or any
#' broker error yields \code{persisted = FALSE} with a typed error code and
#' never falls back to a caller-owned sink. On Windows and other non-Linux
#' platforms the transport is unavailable and every call returns
#' \code{runix_broker_unavailable}.
#'
#' @param socket_path The broker's \code{AF_UNIX} socket path (broker
#'   configuration; a client never chooses where root writes).
#' @param connect_ms Millisecond deadline for the connect.
#' @param recv_ms Millisecond deadline for reading the response.
#' @param send_ms Millisecond deadline for writing the request.
#' @param audit_scope The scope stamped on receipts (\code{"system"}).
#' @return A sink implementing \code{open_intent}, \code{write_outcome},
#'   \code{emit}, plus \code{kind}/\code{audit_scope}/\code{durability}/
#'   \code{socket_path}.
#' @examples
#' # Requires a running broker; constructed here without connecting.
#' s <- broker_audit_sink("/run/runix/audit-broker.sock")
#' s$kind
#' @export
broker_audit_sink <- function(socket_path = "/run/runix/audit-broker.sock",
                              connect_ms = 2000L, recv_ms = 5000L,
                              send_ms = 5000L, audit_scope = "system") {
    force(socket_path)

    ## Encode + send a request; return a validated response or a typed failure.
    call <- function(req) {
        body <- tryCatch(encode_json_line(req), error = function(e) e)
        if (inherits(body, "condition")) {
            return(list(kind = "invalid", error = "runix_broker_bad_request"))
        }
        res <- .broker_call(socket_path, body, connect_ms, recv_ms, send_ms)
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

    open_intent <- function(record) {
        v <- call(list(type = "open_intent", record = record))
        if (!identical(v$kind, "open_ok")) {
            return(list(correlation_id = NA_character_, persisted = FALSE,
                        audit_scope = audit_scope, binding = NA_character_,
                        error = .broker_err_code(v)))
        }
        ## the binding lives ONLY here, in the in-memory receipt, for the paired
        ## write_outcome; it is never logged or written anywhere else.
        list(correlation_id = v$fields$correlation_id, persisted = TRUE,
             audit_scope = v$fields$audit_scope, binding = v$fields$binding,
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

    emit <- function(record, phase = "outcome", correlation_id = NULL) {
        ## the broker mints ids; a caller-supplied correlation_id is ignored.
        v <- call(list(type = "emit", phase = phase, record = record))
        if (!identical(v$kind, "emit_ok")) {
            return(list(correlation_id = NA_character_, persisted = FALSE,
                        audit_scope = audit_scope, binding = NULL,
                        error = .broker_err_code(v)))
        }
        list(correlation_id = v$fields$correlation_id, persisted = TRUE,
             audit_scope = v$fields$audit_scope, binding = NULL, error = NULL)
    }

    ## The broker exposes no generic append: emit/open_intent/write_outcome are
    ## the only paths. A direct write() fails closed rather than pretend.
    write <- function(record) {
        list(persisted = FALSE, error = "runix_broker_no_generic_write")
    }

    list(open_intent = open_intent, write_outcome = write_outcome, emit = emit,
         write = write, kind = "broker", audit_scope = audit_scope,
         durability = "fsync", socket_path = socket_path)
}
