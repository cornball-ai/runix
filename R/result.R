#' Construct a subsystem-neutral Runix result object
#'
#' The shared shape for a mutation result. Domain packages subclass it —
#' e.g. rsystemd builds \code{c("systemd_result", "runix_result")} — and put
#' subsystem specifics inside \code{completion}/\code{before}/\code{after}.
#' The core object carries no systemd/apt fields.
#'
#' @param operation Dotted verb (e.g. \code{"systemd.restart"}).
#' @param resource The object acted on.
#' @param changed Verb-specific functional effect (logical; \code{NA} when
#'   unconfirmable, e.g. a submitted-but-unconfirmed job).
#' @param state_changed Raw observed-field transition (logical; \code{NA}
#'   when unconfirmable).
#' @param preview Was this a dry run?
#' @param before,after Observed pre/post state (\code{after} \code{NA} in a
#'   preview).
#' @param planned The intended change (always present).
#' @param completion How the job was correlated (method, evidence).
#' @param audit The audit record (built by the subsystem).
#' @param subclass Character vector prepended to \code{"runix_result"}.
#' @return An S3 object of class \code{c(subclass, "runix_result")}.
#' @examples
#' new_runix_result("demo.op", "thing", TRUE, TRUE, FALSE,
#'     before = list(), after = list(), planned = list(),
#'     completion = list(method = "noop"), audit = list(outcome = "ok"))
#' @export
new_runix_result <- function(operation, resource, changed, state_changed,
                             preview, before, after, planned, completion,
                             audit, subclass = character()) {
    structure(
              list(operation = operation, resource = resource, changed = changed,
                   state_changed = state_changed, preview = preview,
                   before = before, after = after, planned = planned,
                   completion = completion, audit = audit),
              class = c(subclass, "runix_result")
    )
}

#' @export
print.runix_result <- function(x, ...) {
    if (isTRUE(x$preview)) {
        tag <- " [preview]"
    } else {
        tag <- ""
    }
    cat(sprintf("%s %s%s: changed=%s state_changed=%s\n", x$operation,
                x$resource, tag, x$changed, x$state_changed))
    invisible(x)
}
