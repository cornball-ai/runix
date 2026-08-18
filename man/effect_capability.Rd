% tinyrox says don't edit this manually, but it can't stop you!
\name{effect_capability}
\alias{effect_capability}
\title{Negotiate the broker's effect-receipt capability}
\usage{
effect_capability(
  socket_path = "/run/runix-audit.sock",
  plan_schema = 1L,
  connect_ms = 2000L,
  recv_ms = 5000L,
  send_ms = 5000L
)
}
\arguments{
\item{socket_path}{The broker's \code{AF_UNIX} socket path.}

\item{plan_schema}{The plan-digest schema the issuer needs (a positive
integer; the arc uses schema 1). Must appear in the broker's advertised
\code{plan_schemas}.}

\item{connect_ms,recv_ms,send_ms}{Millisecond deadlines for the exchange.}
}
\value{
A \code{runix_effect_capability} object listing the negotiated
  \code{effect_receipt} extension version, the accepted \code{plan_schema},
  the full \code{plan_schemas} vector, and the broker's \code{frame_version}
  / \code{record_schema_version}. Raises \code{runix_capability_unavailable}
  on any failure.
}
\description{
Sends the broker's \code{capabilities} query and confirms the reply
advertises the \strong{effect-receipt extension} and accepts the required
\strong{plan schema}, before any intent is opened. This is the real
compatibility gate on top of \code{\link{broker_available}}'s cheap liveness
probe: a live, root-authenticated broker that does not speak the effect
extension (or a different plan schema) cannot mint a usable receipt, and an
issuer must learn that \emph{before} minting anything.
}
\details{
The broker peer is pinned to root (\code{uid 0}), exactly like
\code{broker_available()}; there is no caller-supplied uid, so nothing can
lower the authentication bar.

Fail-closed: an unreachable or untrusted broker, a broker that does not
recognise the query (\code{unknown_request}) or omits the extension, or one
that does not accept \code{plan_schema} all raise
\code{runix_capability_unavailable}. Nothing is minted on any path.

}
\examples{
\dontrun{
cap <- effect_capability("/run/runix-audit.sock", plan_schema = 1L)
}
}
\seealso{
\code{\link{broker_available}} for the liveness probe;
  \code{\link{effect_session_open}} for the intent this gates.
}
