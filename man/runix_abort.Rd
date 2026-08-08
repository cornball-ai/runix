% tinyrox says don't edit this manually, but it can't stop you!
\name{runix_abort}
\alias{runix_abort}
\title{Raise a typed Runix condition}
\usage{
runix_abort(
  message,
  subclass = character(),
  data = list(),
  call = sys.call(-1)
)
}
\arguments{
\item{message}{Character scalar (already assembled).}

\item{subclass}{Character vector of most-specific classes, prepended to
the canonical \code{runix_error/error/condition} tail.}

\item{data}{Named list merged onto the condition object.}

\item{call}{The originating call.}
}
\value{
Never returns; raises the condition.
}
\description{
The single definition of the Runix condition taxonomy. Builds a condition
with class \code{c(subclass, "runix_error", "error", "condition")} and
merges \code{data} onto the object, so callers branch on class and read
structured fields (resource, observed, elapsed, ...) without parsing the
message. Subsystem packages wrap this with a fixed package subclass
(e.g. \code{stop_pkgstate} passes \code{subclass = c(class,
"pkgstate_error")}); \code{"runix_parse_error"} is a documented subclass
string callers pass in \code{subclass}.
}
\examples{
\dontrun{
runix_abort("no such unit", subclass = c("rsystemd_error"),
            data = list(resource = "x.service"))
}
}
