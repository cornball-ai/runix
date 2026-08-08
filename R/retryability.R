## Retryability registry: the single source of truth for which condition
## classes an agent may safely retry. Subsystem packages declare their
## retryable classes (typically in .onLoad); rctl and other consumers query
## `is_retryable()` rather than reconstructing retryability from class-name
## strings.

.retryable <- new.env(parent = emptyenv())
.retryable$classes <- character()

#' Register retryable condition classes
#'
#' @param ... Condition class names that are safe to retry.
#' @return Invisibly, the full set of registered retryable classes.
#' @examples
#' register_retryable("pkgstate_cache_race")
#' @export
register_retryable <- function(...) {
    cls <- c(...)
    if (length(cls) > 0L && !is.character(cls)) {
        stop("retryable classes must be character")
    }
    .retryable$classes <- union(.retryable$classes, cls)
    invisible(.retryable$classes)
}

#' Is a condition retryable?
#'
#' @param cond A condition object.
#' @return \code{TRUE} if any of the condition's classes is registered
#'   retryable, else \code{FALSE}.
#' @examples
#' register_retryable("pkgstate_cache_race")
#' e <- structure(class = c("pkgstate_cache_race", "runix_error", "error",
#'     "condition"), list(message = "x"))
#' is_retryable(e)
#' @export
is_retryable <- function(cond) {
    any(class(cond) %in% .retryable$classes)
}
