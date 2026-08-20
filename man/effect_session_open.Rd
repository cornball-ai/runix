% tinyrox says don't edit this manually, but it can't stop you!
\name{effect_session_open}
\alias{effect_session_open}
\title{Open an effect-bearing intent and mint a single-use receipt}
\usage{
effect_session_open(
  socket_path,
  operation,
  resource,
  plan_schema,
  plan_hash,
  connect_ms = 2000L,
  recv_ms = 5000L,
  send_ms = 5000L
)
}
\arguments{
\item{socket_path}{The broker's \code{AF_UNIX} socket path.}

\item{operation}{A contracted apt operation, e.g. \code{"apt.install"} (the
runix-owned closed set; the C side maps it to the immutable entrypoint, so
no path ever crosses from R).}

\item{resource}{The intent's bound resource string. Non-empty for a targeted
verb (\code{apt.install}/\code{remove}/\code{purge}/\code{hold}/\code{unhold});
the empty string \code{""} for a whole-system verb
(\code{apt.update}/\code{upgrade}/\code{dist_upgrade}/\code{configure}), which
binds no package.}

\item{plan_schema}{The plan-digest schema (a positive integer; matches the
value negotiated by \code{\link{effect_capability}}).}

\item{plan_hash}{The 64-hex SHA-256 plan digest bound into the receipt.}

\item{connect_ms,recv_ms,send_ms}{Millisecond deadlines for the exchange.}
}
\value{
A \code{runix_effect_session} handle object. Raises a typed condition
  (\code{runix_broker_unavailable} / \code{_timeout} /
  \code{_untrusted_peer} / \code{_bad_response} / \code{_error}) on failure.
}
\description{
Opens an \code{open_intent} carrying an \code{effect} block over the broker's
native effect-session transport. On success the broker mints a single-use
\strong{effect receipt} (to authorize the commit) and an \strong{outcome
binding} (to close the durable record); both are 128-bit secrets held in
wipeable C heap and \emph{never} become R objects. R receives only an opaque,
process-bound handle and the non-secret correlation id.
}
\details{
The returned handle is bound to the opening process: a handle used from a
\code{fork}ed child, or restored from \code{unserialize}, is refused (its
pointer address is not serialized). Dropping the handle without writing an
outcome leaves the intent open -- the correct fail-closed state.

This is the ONLY way to obtain a receipt: an effect-bearing request sent
through the generic broker client is refused
(\code{runix_effect_via_generic_path}), so the receipt cannot reach R.

}
\examples{
\dontrun{
h <- effect_session_open("/run/runix-audit.sock", "apt.install", "nginx",
                         plan_schema = 1L, plan_hash = strrep("0", 64))
}
}
\seealso{
\code{\link{effect_capability}} (the gate that must precede this),
  \code{\link{effect_session_commit}}, \code{\link{effect_session_write_outcome}}.
}
