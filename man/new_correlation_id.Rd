% tinyrox says don't edit this manually, but it can't stop you!
\name{new_correlation_id}
\alias{new_correlation_id}
\title{Mint a correlation id for a mutation operation}
\usage{
new_correlation_id(clock = sys_clock(), pid = Sys.getpid(), counter = NULL)
}
\arguments{
\item{clock}{A clock function (see \code{\link{sys_clock}}).}

\item{pid}{Process id (defaults to this process).}

\item{counter}{Optional integer; when given, the suffix is deterministic.}
}
\value{
A length-1 character correlation id.
}
\description{
Time-orderable so a sorted sink is chronological: a zero-padded microsecond
timestamp, the pid, and a suffix. The suffix is a counter when supplied
(deterministic, for tests) or random hex otherwise. Unique per attempt and
meant to be stable across a mutation's intent record, outcome record,
result object, and any raised condition.
}
\examples{
new_correlation_id(counter = 1L)
}
