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
