% tinyrox says don't edit this manually, but it can't stop you!
\name{broker_available}
\alias{broker_available}
\title{Is a root-authenticated audit broker reachable right now?}
\usage{
broker_available(socket_path = "/run/runix-audit.sock", connect_ms = 500L)
}
\arguments{
\item{socket_path}{The broker's \code{AF_UNIX} socket path.}

\item{connect_ms}{Millisecond deadline for the connect.}
}
\value{
One of \code{"available"} (a root peer answered),
  \code{"unavailable"} (no socket / refused), \code{"untrusted"} (a non-root
  peer), \code{"timeout"}, \code{"unsupported"} (not Linux), or
  \code{"error"}.
}
\description{
A bounded, side-effect-free runtime probe: it connects to the broker socket,
authenticates the peer's kernel-verified uid (\code{SO_PEERCRED}) as root, and
closes WITHOUT sending a request, so no audit record is ever written. This is
the honest basis for \code{\link{system_durable_audit_available}} -- never a
caller Boolean, socket-existence inference, or static sink metadata.
}
\examples{
broker_available(tempfile(fileext = ".sock"))
}
