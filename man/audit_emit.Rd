% tinyrox says don't edit this manually, but it can't stop you!
\name{audit_emit}
\alias{audit_emit}
\title{Emit a single framed audit record}
\usage{
audit_emit(
  sink,
  record,
  phase = "outcome",
  correlation_id = new_correlation_id(),
  clock = sys_clock()
)
}
\arguments{
\item{sink}{An audit sink (see \code{\link{file_audit_sink}}).}

\item{record}{A named list: the record's domain content.}

\item{phase}{Record phase, e.g. \code{"intent"}, \code{"outcome"},
\code{"preview"}, \code{"noop"}.}

\item{correlation_id}{The operation id (mint with
\code{\link{new_correlation_id}}); default mints a fresh one.}

\item{clock}{A clock function for the timestamp.}
}
\value{
\code{list(persisted, correlation_id, error)}.
}
\description{
Frames a domain record (adds \code{schema_version}, \code{correlation_id},
\code{phase}, \code{host}, \code{pid}, \code{time}) and writes it once. The
primitive behind \code{\link{audit_two_phase}}, and the right tool for a
non-effect path (a preview or a pre-effect no-op) that the contract records
with a single record rather than an intent/outcome pair.
}
\examples{
s <- memory_audit_sink()
audit_emit(s, list(operation = "demo.op", effect_issued = FALSE,
    outcome = "preview"), phase = "preview")$persisted
}
