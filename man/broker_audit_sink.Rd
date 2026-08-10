% tinyrox says don't edit this manually, but it can't stop you!
\name{broker_audit_sink}
\alias{broker_audit_sink}
\title{An AF_UNIX audit-broker client sink}
\usage{
broker_audit_sink(
  socket_path = "/run/runix-audit.sock",
  connect_ms = 2000L,
  recv_ms = 5000L,
  send_ms = 5000L
)
}
\arguments{
\item{socket_path}{The broker's \code{AF_UNIX} socket path (broker
configuration; a client never chooses where root writes).}

\item{connect_ms}{Millisecond deadline for the connect.}

\item{recv_ms}{Millisecond deadline for reading the response.}

\item{send_ms}{Millisecond deadline for writing the request.}
}
\value{
A sink implementing \code{open_intent}, \code{write_outcome},
  \code{emit}, plus \code{kind}/\code{audit_scope}/\code{durability}/
  \code{socket_path}.
}
\description{
Constructs the sink that writes SYSTEM-durable audit through the privileged
\code{runix-audit-broker} daemon over a local \code{AF_UNIX} socket, so an
unprivileged mutation can obtain a record it could not write to the
root-owned system sink itself. It implements the same receipt lifecycle as
\code{\link{file_audit_sink}} (\code{open_intent}/\code{write_outcome}/
\code{emit}), but the broker mints correlation ids server-side and returns an
opaque \code{binding} carried only in the in-memory receipt. \code{emit}
accepts only the non-effect phases \code{"preview"}/\code{"noop"} (enforced
locally as well as by the broker).
}
\details{
The client authenticates the server: before any request byte is sent, the
peer's kernel-verified uid (\code{SO_PEERCRED}) must be root, so a malicious
local socket cannot impersonate the broker and fake a persisted response.
Fail-closed throughout: a missing socket, an untrusted peer, a timeout, a
malformed response, or any broker error yields \code{persisted = FALSE} with
a typed error code and never falls back to a caller-owned sink; a failed
receipt claims no \code{audit_scope}. The broker is Linux-only: on Windows,
macOS, and other platforms every call returns
\code{runix_broker_unavailable}.

}
\examples{
# Requires a running broker; constructed here without connecting.
s <- broker_audit_sink("/run/runix-audit.sock")
s$kind
}
