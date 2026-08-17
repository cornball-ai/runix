## The contract-compatibility gate that must precede any effect-bearing intent.
## `broker_available()` only authenticates the peer and confirms the socket
## answers; it does NOT establish that the broker speaks the effect-receipt
## extension at the plan schema the issuer needs. This is that negotiation.

#' Negotiate the broker's effect-receipt capability
#'
#' Sends the broker's \code{capabilities} query and confirms the reply
#' advertises the \strong{effect-receipt extension} and accepts the required
#' \strong{plan schema}, before any intent is opened. This is the real
#' compatibility gate on top of \code{\link{broker_available}}'s cheap liveness
#' probe: a live, root-authenticated broker that does not speak the effect
#' extension (or a different plan schema) cannot mint a usable receipt, and an
#' issuer must learn that \emph{before} minting anything.
#'
#' The broker peer is pinned to root (\code{uid 0}), exactly like
#' \code{broker_available()}; there is no caller-supplied uid, so nothing can
#' lower the authentication bar.
#'
#' Fail-closed: an unreachable or untrusted broker, a broker that does not
#' recognise the query (\code{unknown_request}) or omits the extension, or one
#' that does not accept \code{plan_schema} all raise
#' \code{runix_capability_unavailable}. Nothing is minted on any path.
#'
#' @param socket_path The broker's \code{AF_UNIX} socket path.
#' @param plan_schema The plan-digest schema the issuer needs (a positive
#'   integer; the arc uses schema 1). Must appear in the broker's advertised
#'   \code{plan_schemas}.
#' @param connect_ms,recv_ms,send_ms Millisecond deadlines for the exchange.
#' @return Invisibly, a \code{runix_effect_capability} object listing the
#'   negotiated \code{effect_receipt} extension version, the accepted
#'   \code{plan_schema}, the full \code{plan_schemas} vector, and the broker's
#'   \code{frame_version} / \code{record_schema_version}. Raises
#'   \code{runix_capability_unavailable} on any failure.
#' @seealso \code{\link{broker_available}} for the liveness probe;
#'   \code{\link{effect_session_open}} for the intent this gates.
#' @examples
#' \dontrun{
#' cap <- effect_capability("/run/runix-audit.sock", plan_schema = 1L)
#' }
#' @export
effect_capability <- function(socket_path = "/run/runix-audit.sock",
                              plan_schema = 1L, connect_ms = 2000L,
                              recv_ms = 5000L, send_ms = 5000L) {
    ## uid 0: the broker is always root; the exported entry pins the peer and
    ## exposes no uid, so nothing can lower the authentication bar.
    .effect_capability(socket_path, plan_schema, connect_ms, recv_ms,
                       send_ms, expected_uid = 0L)
}

## The capability negotiation with an explicit expected peer uid. The exported
## effect_capability() pins it to root (0); tests pass a non-root uid to drive
## the logic against an unprivileged fake broker (mirrors .broker_audit_sink).
.effect_capability <- function(socket_path, plan_schema = 1L,
                               connect_ms = 2000L, recv_ms = 5000L,
                               send_ms = 5000L, expected_uid = 0L) {
    plan_schema <- suppressWarnings(as.integer(plan_schema))
    if (length(plan_schema) != 1L || is.na(plan_schema) || plan_schema < 1L) {
        stop("plan_schema must be a single positive integer")
    }
    ## Every failure exits through here as a single fail-closed condition; the
    ## structured `data` lets a caller branch without parsing the message.
    fail <- function(reason, data = list()) {
        runix_abort(
                    sprintf("broker effect-receipt capability unavailable: %s", reason),
                    subclass = "runix_capability_unavailable",
                    data = c(list(socket_path = socket_path,
                                  plan_schema = plan_schema, reason = reason), data))
    }

    body <- tryCatch(encode_json_line(list(type = "capabilities")),
                     error = function(e) e)
    if (inherits(body, "condition")) {
        fail("could not encode the capabilities request")
    }
    res <- .broker_call(socket_path, body, connect_ms, recv_ms, send_ms,
                        as.integer(expected_uid))
    if (!identical(as.integer(res$status), .RAB_ST_OK)) {
        fail("broker unreachable or untrusted",
             data = list(transport = .broker_status_error(res$status)))
    }
    v <- .broker_parse_response(res$body)
    if (!identical(v$kind, "capabilities_ok")) {
        ## a broker without the extension may answer `unknown_request`, return a
        ## non-capabilities shape, or a malformed body -- all "no capability".
        fail("broker did not return a valid capabilities response",
             data = list(broker = .broker_err_code(v)))
    }
    ext <- v$fields$extensions[["effect_receipt"]]
    if (!.broker_is_count(ext)) {
        fail("broker does not advertise the effect-receipt extension")
    }
    schemas <- vapply(v$fields$plan_schemas, as.integer, integer(1))
    if (!(plan_schema %in% schemas)) {
        fail(sprintf("broker does not accept plan_schema %d", plan_schema),
             data = list(plan_schemas = schemas))
    }

    structure(
              list(effect_receipt = as.integer(ext), plan_schema = plan_schema,
                   plan_schemas = schemas,
                   frame_version = as.integer(v$fields$frame_version),
                   record_schema_version =
                   as.integer(v$fields$record_schema_version)),
              class = "runix_effect_capability")
}

#' @export
print.runix_effect_capability <- function(x, ...) {
    cat(sprintf(paste0("<runix effect capability: effect_receipt v%d, ",
                       "plan_schema %d of {%s}, frame v%d>\n"),
                x$effect_receipt, x$plan_schema,
                paste(x$plan_schemas, collapse = ", "), x$frame_version))
    invisible(x)
}
