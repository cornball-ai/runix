% tinyrox says don't edit this manually, but it can't stop you!
\name{new_runix_result}
\alias{new_runix_result}
\title{Construct a subsystem-neutral Runix result object}
\usage{
new_runix_result(
  operation,
  resource,
  changed,
  state_changed,
  preview,
  before,
  after,
  planned,
  completion,
  audit,
  subclass = character()
)
}
\arguments{
\item{operation}{Dotted verb (e.g. \code{"systemd.restart"}).}

\item{resource}{The object acted on.}

\item{changed}{Verb-specific functional effect (logical; \code{NA} when
unconfirmable, e.g. a submitted-but-unconfirmed job).}

\item{state_changed}{Raw observed-field transition (logical; \code{NA}
when unconfirmable).}

\item{preview}{Was this a dry run?}

\item{planned}{The intended change (always present).}

\item{completion}{How the job was correlated (method, evidence).}

\item{audit}{The audit record (built by the subsystem).}

\item{subclass}{Character vector prepended to \code{"runix_result"}.}

\item{before,after}{Observed pre/post state (\code{after} \code{NA} in a
preview).}
}
\value{
An S3 object of class \code{c(subclass, "runix_result")}.
}
\description{
The shared shape for a mutation result. Domain packages subclass it —
e.g. rsystemd builds \code{c("systemd_result", "runix_result")} — and put
subsystem specifics inside \code{completion}/\code{before}/\code{after}.
The core object carries no systemd/apt fields.
}
\examples{
new_runix_result("demo.op", "thing", TRUE, TRUE, FALSE,
    before = list(), after = list(), planned = list(),
    completion = list(method = "noop"), audit = list(outcome = "ok"))
}
