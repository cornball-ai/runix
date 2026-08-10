% tinyrox says don't edit this manually, but it can't stop you!
\name{system_durable_audit_available}
\alias{system_durable_audit_available}
\title{Is system-durable audit available on this host?}
\usage{
system_durable_audit_available(
  root = .euid_is_root(),
  socket_path = "/run/runix-audit.sock",
  connect_ms = 500L
)
}
\arguments{
\item{root}{Is the effective user root? (injectable; default detects.)}

\item{socket_path}{The broker's \code{AF_UNIX} socket path.}

\item{connect_ms}{Millisecond deadline for the probe connect.}
}
\value{
\code{TRUE} or \code{FALSE}.
}
\description{
True only when a mutation's audit can be written durably to the root-owned
system sink: the caller is root, or a root-authenticated audit broker is
reachable. Broker availability is a bounded, side-effect-free RUNTIME probe
(\code{\link{broker_available}}) that authenticates the broker peer as root
via \code{SO_PEERCRED} and writes nothing; it is never inferred from a caller
Boolean, the socket's existence, or a sink's static metadata. A fleet policy
reads this to refuse system-scope mutations that would only be caller-durably
audited.
}
\examples{
system_durable_audit_available(root = FALSE,
    socket_path = tempfile(fileext = ".sock"))
}
