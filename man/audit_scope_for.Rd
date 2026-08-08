% tinyrox says don't edit this manually, but it can't stop you!
\name{audit_scope_for}
\alias{audit_scope_for}
\title{The audit scope a mutation's record would be written under}
\usage{
audit_scope_for(scope = c("system", "user"), root = .euid_is_root())
}
\arguments{
\item{scope}{\code{"system"} or \code{"user"}.}

\item{root}{Is the effective user root? (injectable; default detects.)}
}
\value{
One of \code{"system"}, \code{"user"}, \code{"caller"}.
}
\description{
Per the authority matrix: root writes the system sink (\code{"system"}); a
user-scope mutation writes the caller-owned sink (\code{"user"}); an
unprivileged system-scope mutation writes the caller-owned sink but is
honest that it is not system-durable (\code{"caller"}).
}
\examples{
audit_scope_for("system", root = FALSE)
audit_scope_for("system", root = TRUE)
}
