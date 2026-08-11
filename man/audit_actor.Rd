% tinyrox says don't edit this manually, but it can't stop you!
\name{audit_actor}
\alias{audit_actor}
\title{The caller's normalized audit actor}
\usage{
audit_actor()
}
\value{
A length-1 character \code{"uid:<n>"}, or \code{"uid:unknown"} when
  the uid cannot be read.
}
\description{
The \code{"uid:<numeric uid>"} identity a local sink stamps on an audit
record. \code{actor} is authority-derived framing metadata, not domain
content: a file/memory sink derives it here from the writing process, and
the audit broker derives it from the peer's kernel-verified credentials
(\code{SO_PEERCRED}). A subsystem never supplies \code{actor} in a record it
hands a sink (the broker rejects a client-supplied one; see
\code{audit-broker-contract.md}). The numeric uid is authoritative; a display
name is deliberately not part of the value.
}
\examples{
audit_actor()
}
