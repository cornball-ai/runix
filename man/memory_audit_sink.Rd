% tinyrox says don't edit this manually, but it can't stop you!
\name{memory_audit_sink}
\alias{memory_audit_sink}
\title{An in-memory audit sink for tests and consumers}
\usage{
memory_audit_sink(fail_on = NULL, durability = "memory")
}
\arguments{
\item{fail_on}{Optional \code{function(record)}; when it returns
\code{TRUE}, that write reports \code{persisted = FALSE} and the record
is not stored (as if the sink failed).}

\item{durability}{Reported durability label (default \code{"memory"}).}
}
\value{
A sink with an extra \code{records()} accessor.
}
\description{
Records are appended to an in-memory list instead of a file. Useful for
testing consumers offline and for exercising failure handling: pass
\code{fail_on} to simulate a persistence failure for matching records.
}
\examples{
s <- memory_audit_sink()
s$write(list(outcome = "ok"))
length(s$records())
}
