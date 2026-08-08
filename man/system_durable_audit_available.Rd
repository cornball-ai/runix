% tinyrox says don't edit this manually, but it can't stop you!
\name{system_durable_audit_available}
\alias{system_durable_audit_available}
\title{Is system-durable audit available on this host?}
\usage{
system_durable_audit_available(root = .euid_is_root(), broker = FALSE)
}
\arguments{
\item{root}{Is the effective user root? (injectable; default detects.)}

\item{broker}{Is the audit broker present? (default \code{FALSE}; no broker
yet.)}
}
\value{
\code{TRUE} or \code{FALSE}.
}
\description{
True only when a mutation's audit can be written durably to the
root-owned system sink: the caller is root, or a privileged audit broker is
present. No broker exists yet, so this is root-only for now. A fleet policy
reads this to refuse system-scope mutations that would only be
caller-durably audited.
}
\examples{
system_durable_audit_available(root = FALSE)
}
