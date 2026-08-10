## Two-phase audit orchestration (durable-audit-contract.md). Kept generic:
## the driver takes an effect thunk and record builders, so it is isolated
## from any subsystem's mutation implementation. Subsystems build the domain
## record content; the core owns correlation, ordering, and the honest
## persisted flag.

#' A UTC wall-clock function
#'
#' @return A function of no arguments returning the current time as a
#'   \code{POSIXct} in UTC. Injectable so callers (and tests) can substitute a
#'   fixed clock.
#' @examples
#' clk <- sys_clock()
#' inherits(clk(), "POSIXct")
#' @export
sys_clock <- function() {
    function() {
        t <- Sys.time()
        attr(t, "tzone") <- "UTC"
        t
    }
}

#' Mint a correlation id for a mutation operation
#'
#' Time-orderable so a sorted sink is chronological: a zero-padded microsecond
#' timestamp, the pid, and a suffix. The suffix is a counter when supplied
#' (deterministic, for tests) or random hex otherwise. Unique per attempt and
#' meant to be stable across a mutation's intent record, outcome record,
#' result object, and any raised condition.
#'
#' @param clock A clock function (see \code{\link{sys_clock}}).
#' @param pid Process id (defaults to this process).
#' @param counter Optional integer; when given, the suffix is deterministic.
#' @return A length-1 character correlation id.
#' @examples
#' new_correlation_id(counter = 1L)
#' @export
new_correlation_id <- function(clock = sys_clock(), pid = Sys.getpid(),
                               counter = NULL) {
    t <- clock()
    micros <- sprintf("%020.0f", as.numeric(t) * 1e6)
    suffix <- if (is.null(counter)) {
        .rand_hex(8L)
    } else {
        sprintf("%08x", as.integer(counter))
    }
    paste0(micros, "-", pid, "-", suffix)
}

.rand_hex <- function(n) {
    paste(sprintf("%x", sample.int(16L, n, replace = TRUE) - 1L), collapse = "")
}

.nodename <- function() {
    nn <- tryCatch(Sys.info()[["nodename"]], error = function(e) NA_character_)
    if (is.null(nn) || is.na(nn)) {
        "unknown"
    } else {
        nn
    }
}

## Merge the framing fields onto a domain record in deterministic key order.
## `record_type` distinguishes a user-visible audit event from a sink's internal
## records (e.g. the broker's checkpoints); see durable-audit-contract.md.
.finish_record <- function(rec, cid, phase, time) {
    c(list(schema_version = 1L, record_type = "audit", correlation_id = cid,
            phase = phase, host = .nodename(), pid = Sys.getpid()),
        rec,
        list(time = time))
}

#' Emit a single framed audit record
#'
#' Frames a domain record (adds \code{schema_version}, \code{record_type},
#' \code{correlation_id}, \code{phase}, \code{host}, \code{pid}, \code{time})
#' and writes it once. The
#' primitive behind \code{\link{audit_two_phase}}, and the right tool for a
#' non-effect path (a preview or a pre-effect no-op) that the contract records
#' with a single record rather than an intent/outcome pair.
#'
#' @param sink An audit sink (see \code{\link{file_audit_sink}}).
#' @param record A named list: the record's domain content.
#' @param phase Record phase, e.g. \code{"preview"} or \code{"noop"}. Required:
#'   a single-record emit must name what it records. A broker sink accepts only
#'   the non-effect phases \code{"preview"}/\code{"noop"}; local sinks also
#'   accept other phases for their own record-keeping.
#' @param correlation_id Optional operation id; default lets the sink mint one
#'   (the broker mints server-side; local sinks use their \code{id_fn}).
#' @return A receipt: \code{list(correlation_id, persisted, audit_scope,
#'   binding, error)}.
#' @examples
#' s <- memory_audit_sink()
#' audit_emit(s, list(operation = "demo.op", effect_issued = FALSE,
#'     outcome = "preview"), phase = "preview")$persisted
#' @export
audit_emit <- function(sink, record, phase, correlation_id = NULL) {
    stopifnot(is.list(record), is.character(phase), length(phase) == 1L)
    if (is.null(correlation_id)) {
        sink$emit(record, phase)
    } else {
        sink$emit(record, phase, correlation_id)
    }
}

#' Run a mutation under the two-phase durable-audit discipline
#'
#' Writes a durable \emph{intent} record before the effect boundary, issues the
#' effect, then writes an \emph{outcome} record; both share one
#' \code{correlation_id}. If the intent cannot be persisted, the effect is not
#' issued (fail-closed) unless \code{on_intent_failure = "degrade"}. If the
#' effect itself errors, an error outcome record is still written before the
#' error propagates (no silent error paths), and the raised condition is
#' annotated with the \code{correlation_id} and \code{audit_persisted} so a
#' caller can correlate the failure. Outcome-write failure never masks the
#' effect's result or error. \code{audit_persisted} is \code{TRUE} only when
#' both writes persisted.
#'
#' The driver is deliberately generic (it takes callbacks), so it carries no
#' systemd/apt semantics; a subsystem supplies the record content and the
#' effect. The \code{correlation_id} is minted by the \code{sink} (locally, or
#' server-side for a broker sink) via \code{open_intent}, so no remote id
#' authority has to be forced into a local generator.
#'
#' @param sink An audit sink (see \code{\link{file_audit_sink}},
#'   \code{\link{memory_audit_sink}}).
#' @param intent A named list: the intent record's domain content.
#' @param effect \code{function(correlation_id)} that issues the effect and
#'   returns a result (any value) describing what happened.
#' @param outcome \code{function(result)} returning the outcome record's
#'   domain content (a named list).
#' @param on_error Optional \code{function(cond, correlation_id)} returning the
#'   outcome record's domain content when the effect raises, so a typed
#'   failure (its class and observed data) is recorded richly rather than as a
#'   generic error. The original condition is always re-raised unchanged apart
#'   from the added \code{correlation_id}/\code{audit_persisted}.
#' @param on_intent_failure \code{"fail_closed"} (default: abort before any
#'   effect if the intent is not durable) or \code{"degrade"} (proceed, but
#'   report \code{audit_persisted = FALSE}).
#' @return A list with \code{correlation_id}, \code{result} (the effect's
#'   return), \code{audit_scope}, \code{intent_persisted},
#'   \code{outcome_persisted}, and \code{audit_persisted}.
#' @examples
#' s <- memory_audit_sink()
#' out <- audit_two_phase(s,
#'     intent = list(operation = "demo.op", resource = "thing",
#'         effect_issued = FALSE, outcome = "intent"),
#'     effect = function(cid) list(ok = TRUE),
#'     outcome = function(r) list(operation = "demo.op", resource = "thing",
#'         effect_issued = TRUE, outcome = "ok"))
#' out$audit_persisted
#' @export
audit_two_phase <- function(sink, intent, effect, outcome, on_error = NULL,
                            on_intent_failure = c("fail_closed", "degrade")) {
    on_intent_failure <- match.arg(on_intent_failure)
    stopifnot(is.function(effect), is.function(outcome), is.list(intent),
              is.null(on_error) || is.function(on_error))

    receipt <- sink$open_intent(intent)
    if (!isTRUE(receipt$persisted) &&
        identical(on_intent_failure, "fail_closed")) {
        runix_abort(
                    paste0("intent audit not durable; refusing to issue effect (",
                if (is.null(receipt$error)) "unknown" else receipt$error, ")"),
                    subclass = "runix_audit_error",
                    data = list(correlation_id = receipt$correlation_id,
                                phase = "intent"))
    }
    cid <- receipt$correlation_id

    result <- tryCatch(
                       effect(cid),
                       error = function(e) {
        rec <- if (is.null(on_error)) {
            list(outcome = "error", effect_issued = NA,
                 error = conditionMessage(e))
        } else {
            on_error(e, cid)
        }
        st <- sink$write_outcome(receipt, rec)
        ## Annotate but never mask: the original condition (class and data)
        ## is re-raised, plus the correlation id and audit status.
        e$correlation_id <- cid
        e$audit_persisted <- isTRUE(receipt$persisted) && isTRUE(st$persisted)
        stop(e)
    })

    st <- sink$write_outcome(receipt, outcome(result))

    list(correlation_id = cid,
         result = result,
         audit_scope = receipt$audit_scope,
         intent_persisted = isTRUE(receipt$persisted),
         outcome_persisted = isTRUE(st$persisted),
         audit_persisted = isTRUE(receipt$persisted) && isTRUE(st$persisted))
}
