#' Construct an injectable command runner
#'
#' The subsystem-neutral runner machinery. Returns per-instance
#' \code{runner}/\code{set_runner}/\code{sleeper}/\code{set_sleeper} closures
#' over a private state environment, so each subsystem package holds its own
#' injectable runner (tests substitute a fake via \code{set_runner}). The
#' core bakes in **no** subsystem defaults: the environment and the
#' missing-tool condition subclass are supplied by the caller, keeping
#' \code{LC_ALL}/\code{TZ} and command semantics out of the core.
#'
#' @param default_env Character vector passed to \code{system2(env=)}
#'   (e.g. \code{"LC_ALL=C"}, or \code{c("LC_ALL=C", "TZ=UTC")}). Default
#'   none.
#' @param missing_tool_subclass Condition subclass vector for the
#'   backend-tool-not-found error (e.g.
#'   \code{c("pkgstate_missing_tool", "pkgstate_error")}).
#' @return A list of closures: \code{runner()} (returns the active runner —
#'   the default \code{system2} executor, or an injected fake),
#'   \code{set_runner(f)} (inject/restore; returns the previous),
#'   \code{sleeper()}/\code{set_sleeper(f)} (interruptible-wait hook for poll
#'   loops), and \code{run_system} (the default executor itself).
#' @details The default executor captures stdout and, separately, stderr (to
#'   a temp file, so parsers see clean output) and returns
#'   \code{list(status, output, stderr)}. A missing tool raises via
#'   \code{\link{runix_abort}} with \code{missing_tool_subclass}.
#' @examples
#' rr <- new_runner(default_env = "LC_ALL=C",
#'     missing_tool_subclass = c("demo_missing_tool", "demo_error"))
#' old <- rr$set_runner(function(cmd, args) list(status = 0L, output = "x",
#'     stderr = character()))
#' rr$runner()("anything", character())
#' rr$set_runner(old)
#' @export
new_runner <- function(default_env = character(),
                       missing_tool_subclass = "runix_error") {
    state <- new.env(parent = emptyenv())

    run_system <- function(cmd, args) {
        if (Sys.which(cmd) == "") {
            runix_abort(paste0("backend tool not found: ", cmd),
                        subclass = missing_tool_subclass,
                        data = list(resource = cmd))
        }
        errfile <- tempfile("runix-stderr")
        on.exit(unlink(errfile), add = TRUE)
        out <- suppressWarnings(
                                system2(cmd, args, stdout = TRUE, stderr = errfile,
                                        env = default_env))
        status <- attr(out, "status")
        errlines <- if (file.exists(errfile)) {
            readLines(errfile, warn = FALSE)
        } else {
            character()
        }
        list(
             status = if (is.null(status)) 0L else as.integer(status),
             output = as.character(out),
             stderr = errlines
        )
    }

    runner <- function() {
        if (is.null(state$run)) {
            run_system
        } else {
            state$run
        }
    }
    set_runner <- function(run = NULL) {
        old <- state$run
        state$run <- run
        invisible(old)
    }
    sleeper <- function() {
        if (is.null(state$sleep)) {
            Sys.sleep
        } else {
            state$sleep
        }
    }
    set_sleeper <- function(f = NULL) {
        old <- state$sleep
        state$sleep <- f
        invisible(old)
    }

    list(runner = runner, set_runner = set_runner, sleeper = sleeper,
         set_sleeper = set_sleeper, run_system = run_system)
}
