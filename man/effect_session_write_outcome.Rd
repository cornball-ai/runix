% tinyrox says don't edit this manually, but it can't stop you!
\name{effect_session_write_outcome}
\alias{effect_session_write_outcome}
\title{Close an effect session by writing its outcome}
\usage{
effect_session_write_outcome(
  session,
  outcome,
  connect_ms = 2000L,
  recv_ms = 5000L,
  send_ms = 5000L
)
}
\arguments{
\item{session}{A \code{runix_effect_session} from \code{effect_session_open}.}

\item{outcome}{The outcome record, a named list (no \code{binding} field --
that is C-owned and inserted here).}

\item{connect_ms,recv_ms,send_ms}{Millisecond deadlines for the exchange.}
}
\value{
A \code{runix_outcome_result}: a list with \code{status} and
  \code{detail}.
}
\description{
Closes the durable intent with the C-held outcome binding. \code{outcome} is
the outcome record (a named list); it is encoded and the binding inserted in
C, so the binding never crosses from R. The binding is spent by the attempt
regardless of result and wiped; the session moves to closed.
}
\details{
Returns the raw status verbatim (the issuer decides what a non-\code{"ok"}
persist means for the outcome it is closing).

}
\seealso{
\code{\link{effect_session_open}},
  \code{\link{effect_session_commit}}.
}
