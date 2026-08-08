% tinyrox says don't edit this manually, but it can't stop you!
\name{new_runner}
\alias{new_runner}
\title{Construct an injectable command runner}
\usage{
new_runner(default_env = character(), missing_tool_subclass = "runix_error")
}
\arguments{
\item{default_env}{Character vector passed to \code{system2(env=)}
(e.g. \code{"LC_ALL=C"}, or \code{c("LC_ALL=C", "TZ=UTC")}). Default
none.}

\item{missing_tool_subclass}{Condition subclass vector for the
backend-tool-not-found error (e.g.
\code{c("pkgstate_missing_tool", "pkgstate_error")}).}
}
\value{
A list of closures: \code{runner()} (returns the active runner —
  the default \code{system2} executor, or an injected fake),
  \code{set_runner(f)} (inject/restore; returns the previous),
  \code{sleeper()}/\code{set_sleeper(f)} (interruptible-wait hook for poll
  loops), and \code{run_system} (the default executor itself).
}
\description{
The subsystem-neutral runner machinery. Returns per-instance
\code{runner}/\code{set_runner}/\code{sleeper}/\code{set_sleeper} closures
over a private state environment, so each subsystem package holds its own
injectable runner (tests substitute a fake via \code{set_runner}). The
core bakes in **no** subsystem defaults: the environment and the
missing-tool condition subclass are supplied by the caller, keeping
\code{LC_ALL}/\code{TZ} and command semantics out of the core.
}
\details{
The default executor captures stdout and, separately, stderr (to
  a temp file, so parsers see clean output) and returns
  \code{list(status, output, stderr)}. A missing tool raises via
  \code{\link{runix_abort}} with \code{missing_tool_subclass}.
}
\examples{
rr <- new_runner(default_env = "LC_ALL=C",
    missing_tool_subclass = c("demo_missing_tool", "demo_error"))
old <- rr$set_runner(function(cmd, args) list(status = 0L, output = "x",
    stderr = character()))
rr$runner()("anything", character())
rr$set_runner(old)
}
