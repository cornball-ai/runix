% tinyrox says don't edit this manually, but it can't stop you!
\name{default_audit_sink}
\alias{default_audit_sink}
\title{Resolve the audit sink and its authority for a mutation scope}
\usage{
default_audit_sink(
  scope = c("system", "user"),
  root = .euid_is_root(),
  xdg = .xdg_state_home(),
  system_dir = "/var/log/runix",
  broker_socket = "/run/runix-audit.sock",
  ...
)
}
\arguments{
\item{scope}{\code{"system"} or \code{"user"}.}

\item{root}{Is the effective user root? (injectable; default detects.)}

\item{xdg}{XDG state base for the caller-owned path (injectable).}

\item{system_dir}{Directory for the root-owned system sink.}

\item{broker_socket}{The audit broker's \code{AF_UNIX} socket path; an
unprivileged system-scope mutation uses the broker only when a
root-authenticated one is reachable (runtime probe).}

\item{...}{Passed to \code{\link{file_audit_sink}} (e.g. \code{durability}).}
}
\value{
\code{list(sink, path, audit_scope, system_durable_audit)}.
}
\description{
Returns a ready sink plus the honest \code{audit_scope} and
\code{system_durable_audit} for this caller and scope (the authority
matrix). Path is deterministic and fails closed when it cannot be resolved.
}
\examples{
r <- default_audit_sink("user", root = FALSE,
    xdg = tempfile("xdg"), durability = "none")
r$audit_scope
}
