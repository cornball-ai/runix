#' Raise a typed Runix condition
#'
#' The single definition of the Runix condition taxonomy. Builds a condition
#' with class \code{c(subclass, "runix_error", "error", "condition")} and
#' merges \code{data} onto the object, so callers branch on class and read
#' structured fields (resource, observed, elapsed, ...) without parsing the
#' message. Subsystem packages wrap this with a fixed package subclass
#' (e.g. \code{stop_pkgstate} passes \code{subclass = c(class,
#' "pkgstate_error")}); \code{"runix_parse_error"} is a documented subclass
#' string callers pass in \code{subclass}.
#'
#' @param message Character scalar (already assembled).
#' @param subclass Character vector of most-specific classes, prepended to
#'   the canonical \code{runix_error/error/condition} tail.
#' @param data Named list merged onto the condition object.
#' @param call The originating call.
#' @return Never returns; raises the condition.
#' @examples
#' \dontrun{
#' runix_abort("no such unit", subclass = c("rsystemd_error"),
#'             data = list(resource = "x.service"))
#' }
#' @export
runix_abort <- function(message, subclass = character(), data = list(),
                        call = sys.call(-1)) {
    if (!is.list(data)) {
        stop("data must be a list")
    }
    cond <- c(list(message = message, call = call), data)
    stop(structure(cond,
                   class = c(subclass, "runix_error", "error", "condition")))
}

#' The effect-session condition taxonomy
#'
#' Runix has no class registry: a condition's \emph{subclass string is the
#' taxonomy}. These are the subclasses the effect-session arc raises through
#' \code{\link{runix_abort}}; an issuer (pkgops) and \code{rctl} branch on class
#' and read the structured \code{data} fields rather than parsing messages.
#'
#' Raised by \strong{runix} itself:
#' \describe{
#'   \item{\code{runix_capability_unavailable}}{The broker does not speak the
#'     effect-receipt extension, accepts a different plan schema, or is
#'     unreachable (\code{\link{effect_capability}}); or the local platform has
#'     no atomic fd-close primitive so the commit path is refused
#'     (\code{\link{effect_session_commit}}). Fail-closed: nothing is minted.}
#'   \item{\code{runix_broker_unavailable}, \code{runix_broker_timeout},
#'     \code{runix_broker_untrusted_peer}, \code{runix_broker_bad_response},
#'     \code{runix_broker_io}, \code{runix_broker_error}}{Transport or broker
#'     failures raised by \code{\link{effect_session_open}} when the intent could
#'     not be opened.}
#'   \item{\code{runix_effect_via_generic_path}}{An effect-bearing request was
#'     sent through the generic broker client instead of an effect session --
#'     refused so the receipt can never reach R.}
#' }
#'
#' Raised by the \strong{issuer} (pkgops), which owns the branched commit
#' lifecycle and the 12-value commit-status mapping:
#' \describe{
#'   \item{\code{runix_helper_bad_result}}{The commit result was malformed,
#'     truncated, duplicate-keyed, or its correlation id mismatched --
#'     effect-unknown (\code{NA}), intent left open, never auto-retried.}
#'   \item{\code{runix_preview_failed}}{The preview planner returned a non-\code{ok}
#'     status; no intent was opened.}
#'   \item{\code{runix_verification_failed}}{Post-commit state read through
#'     \code{pkgstate} disagreed with the helper's reported status.}
#'   \item{\code{runix_unauthorized}}{Polkit or \code{pkexec} denied the action;
#'     the entrypoint never committed.}
#'   \item{\code{runix_approval_required}}{The action needs an interactive or
#'     asynchronous approval that has not been granted.}
#' }
#'
#' Retryability is registered by owner and phase and means \emph{definitely no
#' effect happened} (see \code{\link{register_retryable}} /
#' \code{\link{is_retryable}}). Runix registers none of these itself: generic
#' transport/timeout errors are NOT retryable (an outcome timeout after the
#' receipt was delivered leaves the effect genuinely unknown), and
#' apt-specific retryable classes (e.g. \code{apt_locked}) are owned and
#' registered by the issuer.
#'
#' @name runix_effect_conditions
#' @seealso \code{\link{runix_abort}}, \code{\link{effect_capability}},
#'   \code{\link{effect_session_open}}
NULL
