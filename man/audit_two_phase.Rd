% tinyrox says don't edit this manually, but it can't stop you!
\name{audit_two_phase}
\alias{audit_two_phase}
\title{Run a mutation under the two-phase durable-audit discipline}
\usage{
audit_two_phase(
  sink,
  intent,
  effect,
  outcome,
  on_error = NULL,
  on_intent_failure = c("fail_closed", "degrade"),
  id_fn = new_correlation_id,
  clock = sys_clock()
)
}
\arguments{
\item{sink}{An audit sink (see \code{\link{file_audit_sink}},
\code{\link{memory_audit_sink}}).}

\item{intent}{A named list: the intent record's domain content.}

\item{effect}{\code{function(correlation_id)} that issues the effect and
returns a result (any value) describing what happened.}

\item{outcome}{\code{function(result)} returning the outcome record's
domain content (a named list).}

\item{on_error}{Optional \code{function(cond, correlation_id)} returning the
outcome record's domain content when the effect raises, so a typed
failure (its class and observed data) is recorded richly rather than as a
generic error. The original condition is always re-raised unchanged apart
from the added \code{correlation_id}/\code{audit_persisted}.}

\item{on_intent_failure}{\code{"fail_closed"} (default: abort before any
effect if the intent is not durable) or \code{"degrade"} (proceed, but
report \code{audit_persisted = FALSE}).}

\item{id_fn}{\code{function()} minting the correlation id (injectable).}

\item{clock}{A clock function for record timestamps.}
}
\value{
A list with \code{correlation_id}, \code{result} (the effect's
  return), \code{intent_persisted}, \code{outcome_persisted}, and
  \code{audit_persisted}.
}
\description{
Writes a durable \emph{intent} record before the effect boundary, issues the
effect, then writes an \emph{outcome} record; both share one
\code{correlation_id}. If the intent cannot be persisted, the effect is not
issued (fail-closed) unless \code{on_intent_failure = "degrade"}. If the
effect itself errors, an error outcome record is still written before the
error propagates (no silent error paths), and the raised condition is
annotated with the \code{correlation_id} and \code{audit_persisted} so a
caller can correlate the failure. Outcome-write failure never masks the
effect's result or error. \code{audit_persisted} is \code{TRUE} only when
both writes persisted.
}
\details{
The driver is deliberately generic (it takes callbacks), so it carries no
systemd/apt semantics; a subsystem supplies the record content and the
effect.

}
\examples{
s <- memory_audit_sink()
out <- audit_two_phase(s,
    intent = list(operation = "demo.op", resource = "thing",
        effect_issued = FALSE, outcome = "intent"),
    effect = function(cid) list(ok = TRUE),
    outcome = function(r) list(operation = "demo.op", resource = "thing",
        effect_issued = TRUE, outcome = "ok"),
    id_fn = function() new_correlation_id(counter = 1L))
out$audit_persisted
}
