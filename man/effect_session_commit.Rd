% tinyrox says don't edit this manually, but it can't stop you!
\name{effect_session_commit}
\alias{effect_session_commit}
\title{Commit an opened effect session through the pkexec entrypoint}
\usage{
effect_session_commit(
  session,
  packages = character(),
  lock_timeout = 0L,
  deadline_ms = 120000L
)
}
\arguments{
\item{session}{A \code{runix_effect_session} from \code{effect_session_open}.}

\item{packages}{Character vector of Debian package names for the verb
(empty for whole-system verbs like \code{apt.update}).}

\item{lock_timeout}{Seconds in \code{[0, 3600]} to wait for the apt lock.}

\item{deadline_ms}{Wall-clock millisecond budget for the whole commit.}
}
\value{
A \code{runix_commit_result}: a list with \code{session_status},
  \code{status}, \code{effect_issued}, \code{correlation_id}, \code{detail}.
}
\description{
Delivers the held receipt to the session verb's immutable \code{pkexec}
entrypoint and reads the strict result. The verb is taken from the handle
(set at open); no path or receipt crosses from R. The receipt is wiped the
instant it is delivered.
}
\details{
Returns the raw result verbatim -- runix does NOT map the helper's status to
a condition; the issuer owns that mapping (the 12-value commit vocabulary and
the \code{effect_issued} interpretation). \code{session_status} distinguishes
a spoken helper (\code{"ok"}) from \code{"spawn_failed"} /
\code{"unauthorized"} / \code{"effect_unknown"}; \code{effect_issued} is the
helper's own boolean, \code{FALSE} only when the effect provably did not run
and \code{NA} only when it is genuinely unknown.

Raises \code{runix_capability_unavailable} up front on a platform without an
atomic child-side fd-close primitive (the commit path is refused fail-closed
rather than spawn with an unbounded descriptor set).

}
\seealso{
\code{\link{effect_session_open}},
  \code{\link{effect_session_write_outcome}}.
}
