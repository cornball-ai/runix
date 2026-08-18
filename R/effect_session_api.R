## The exported three-call effect-session surface: open -> commit ->
## write_outcome. Thin wrappers over the native C shims (R/effect_session.R):
## they add the opaque, PID-bound handle object, argument-shape checks, and the
## typed-condition surface, but do NOT orchestrate. The issuer (pkgops) drives
## the branched commit lifecycle and maps the 12-status commit vocabulary to
## conditions; runix only provides the mechanism and hands back the raw result.
##
## The handle object carries only the opaque external pointer (whose address is
## not serialized) and the non-secret correlation id. No receipt, binding, or
## socket path is ever visible from R -- those live in wipeable C heap.

## Validate a session object and return its live external-pointer handle. A
## foreign object, or one whose pointer was lost to serialization, is refused.
.session_handle <- function(session) {
    if (!inherits(session, "runix_effect_session") || !is.list(session) ||
        is.null(session$handle) || typeof(session$handle) != "externalptr") {
        stop("not a runix effect session (use effect_session_open())")
    }
    session$handle
}

## Map a non-ok open status to a typed, secret-free condition. Transport
## failures reuse the broker taxonomy; a broker error response carries its code
## in `detail`.
.effect_open_abort <- function(status, detail, socket_path, operation) {
    sub <- switch(status, unavailable = "runix_broker_unavailable",
                  unsupported = "runix_broker_unavailable",
                  timeout = "runix_broker_timeout",
                  untrusted_peer = "runix_broker_untrusted_peer",
                  bad_response = "runix_broker_bad_response",
                  bad_request = "runix_broker_bad_request",
                  io = "runix_broker_io", "runix_broker_error")
    msg <- sprintf("effect session open failed (%s)", status)
    if (!is.na(detail) && nzchar(detail)) {
        msg <- sprintf("%s: %s", msg, detail)
    }
    runix_abort(msg, subclass = sub,
                data = list(status = status,
                            detail = if (is.na(detail)) NA_character_ else detail,
                            socket_path = socket_path, operation = operation))
}

#' Open an effect-bearing intent and mint a single-use receipt
#'
#' Opens an \code{open_intent} carrying an \code{effect} block over the broker's
#' native effect-session transport. On success the broker mints a single-use
#' \strong{effect receipt} (to authorize the commit) and an \strong{outcome
#' binding} (to close the durable record); both are 128-bit secrets held in
#' wipeable C heap and \emph{never} become R objects. R receives only an opaque,
#' process-bound handle and the non-secret correlation id.
#'
#' The returned handle is bound to the opening process: a handle used from a
#' \code{fork}ed child, or restored from \code{unserialize}, is refused (its
#' pointer address is not serialized). Dropping the handle without writing an
#' outcome leaves the intent open -- the correct fail-closed state.
#'
#' This is the ONLY way to obtain a receipt: an effect-bearing request sent
#' through the generic broker client is refused
#' (\code{runix_effect_via_generic_path}), so the receipt cannot reach R.
#'
#' @param socket_path The broker's \code{AF_UNIX} socket path.
#' @param operation A contracted apt operation, e.g. \code{"apt.install"} (the
#'   runix-owned closed set; the C side maps it to the immutable entrypoint, so
#'   no path ever crosses from R).
#' @param resource The intent's bound resource string (non-empty).
#' @param plan_schema The plan-digest schema (a positive integer; matches the
#'   value negotiated by \code{\link{effect_capability}}).
#' @param plan_hash The 64-hex SHA-256 plan digest bound into the receipt.
#' @param connect_ms,recv_ms,send_ms Millisecond deadlines for the exchange.
#' @return A \code{runix_effect_session} handle object. Raises a typed condition
#'   (\code{runix_broker_unavailable} / \code{_timeout} /
#'   \code{_untrusted_peer} / \code{_bad_response} / \code{_error}) on failure.
#' @seealso \code{\link{effect_capability}} (the gate that must precede this),
#'   \code{\link{effect_session_commit}}, \code{\link{effect_session_write_outcome}}.
#' @examples
#' \dontrun{
#' h <- effect_session_open("/run/runix-audit.sock", "apt.install", "nginx",
#'                          plan_schema = 1L, plan_hash = strrep("0", 64))
#' }
#' @export
effect_session_open <- function(socket_path, operation, resource,
                                plan_schema, plan_hash, connect_ms = 2000L,
                                recv_ms = 5000L, send_ms = 5000L) {
    r <- .effect_session_open(socket_path, operation, resource, plan_schema,
                              plan_hash, connect_ms, recv_ms, send_ms)
    if (!identical(r$status, "ok")) {
        .effect_open_abort(r$status, r$detail, socket_path, operation)
    }
    structure(list(handle = r$handle, correlation_id = r$correlation_id),
              class = "runix_effect_session")
}

#' Commit an opened effect session through the pkexec entrypoint
#'
#' Delivers the held receipt to the session verb's immutable \code{pkexec}
#' entrypoint and reads the strict result. The verb is taken from the handle
#' (set at open); no path or receipt crosses from R. The receipt is wiped the
#' instant it is delivered.
#'
#' Returns the raw result verbatim -- runix does NOT map the helper's status to
#' a condition; the issuer owns that mapping (the 12-value commit vocabulary and
#' the \code{effect_issued} interpretation). \code{session_status} distinguishes
#' a spoken helper (\code{"ok"}) from \code{"spawn_failed"} /
#' \code{"unauthorized"} / \code{"effect_unknown"}; \code{effect_issued} is the
#' helper's own boolean, \code{FALSE} only when the effect provably did not run
#' and \code{NA} only when it is genuinely unknown.
#'
#' Raises \code{runix_capability_unavailable} up front on a platform without an
#' atomic child-side fd-close primitive (the commit path is refused fail-closed
#' rather than spawn with an unbounded descriptor set).
#'
#' @param session A \code{runix_effect_session} from \code{effect_session_open}.
#' @param packages Character vector of Debian package names for the verb
#'   (empty for whole-system verbs like \code{apt.update}).
#' @param lock_timeout Seconds in \code{[0, 3600]} to wait for the apt lock.
#' @param deadline_ms Wall-clock millisecond budget for the whole commit.
#' @return A \code{runix_commit_result}: a list with \code{session_status},
#'   \code{status}, \code{effect_issued}, \code{correlation_id}, \code{detail}.
#' @seealso \code{\link{effect_session_open}},
#'   \code{\link{effect_session_write_outcome}}.
#' @export
effect_session_commit <- function(session, packages = character(),
                                  lock_timeout = 0L, deadline_ms = 120000L) {
    h <- .session_handle(session)
    if (!.effect_session_commit_supported()) {
        runix_abort(paste0("effect commit is unavailable on this platform: ",
                           "no atomic close-on-exec primitive to bound the ",
                           "child's inherited descriptors"),
                    subclass = "runix_capability_unavailable",
                    data = list(reason = "no_closefrom_primitive"))
    }
    r <- .effect_session_commit(h, packages, lock_timeout, deadline_ms)
    structure(r, class = "runix_commit_result")
}

#' Close an effect session by writing its outcome
#'
#' Closes the durable intent with the C-held outcome binding. \code{outcome} is
#' the outcome record (a named list); it is encoded and the binding inserted in
#' C, so the binding never crosses from R. The binding is spent by the attempt
#' regardless of result and wiped; the session moves to closed.
#'
#' Returns the raw status verbatim (the issuer decides what a non-\code{"ok"}
#' persist means for the outcome it is closing).
#'
#' @param session A \code{runix_effect_session} from \code{effect_session_open}.
#' @param outcome The outcome record, a named list (no \code{binding} field --
#'   that is C-owned and inserted here).
#' @param connect_ms,recv_ms,send_ms Millisecond deadlines for the exchange.
#' @return A \code{runix_outcome_result}: a list with \code{status} and
#'   \code{detail}.
#' @seealso \code{\link{effect_session_open}},
#'   \code{\link{effect_session_commit}}.
#' @export
effect_session_write_outcome <- function(session, outcome,
    connect_ms = 2000L, recv_ms = 5000L,
    send_ms = 5000L) {
    h <- .session_handle(session)
    if (!is.list(outcome) || is.null(names(outcome)) ||
        any(!nzchar(names(outcome)))) {
        stop("outcome must be a named list")
    }
    r <- .effect_session_write_outcome(h, outcome, connect_ms, recv_ms, send_ms)
    structure(r, class = "runix_outcome_result")
}

#' @export
print.runix_effect_session <- function(x, ...) {
    st <- tryCatch(.effect_session_state(x$handle), error = function(e) NULL)
    if (is.null(st)) {
        state <- "invalid/foreign"
    } else {
        state <- st$state
    }
    cat(sprintf("<runix effect session: %s, cid %s>\n", state,
                x$correlation_id))
    invisible(x)
}
