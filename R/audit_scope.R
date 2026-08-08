## Audit authority resolution (durable-audit-contract.md "authority matrix").
## Chooses the sink and the honest audit_scope by caller privilege and
## mutation scope, and reports whether system-durable audit is available. v1:
## no broker yet, so an unprivileged system-scope caller gets the caller-owned
## sink with audit_scope = "caller" and system_durable_audit = FALSE.

## Is the effective user root? Injectable via callers for testing.
.euid_is_root <- function() {
    eu <- tryCatch(Sys.info()[["effective_user"]],
                   error = function(e) NA_character_)
    identical(eu, "root")
}

## XDG state home, or the ~/.local/state fallback, or "" when unresolvable.
.xdg_state_home <- function() {
    x <- Sys.getenv("XDG_STATE_HOME", unset = "")
    if (nzchar(x)) {
        return(x)
    }
    home <- Sys.getenv("HOME", unset = "")
    if (nzchar(home)) {
        return(file.path(home, ".local", "state"))
    }
    ""
}

## Deterministic caller-owned sink path; fail closed when no base is resolvable.
.xdg_audit_path <- function(xdg = .xdg_state_home()) {
    if (!nzchar(xdg)) {
        runix_abort(
                    "cannot resolve a caller-owned audit path: no XDG_STATE_HOME or HOME",
                    subclass = "runix_audit_error")
    }
    file.path(xdg, "runix", "audit.jsonl")
}

#' The audit scope a mutation's record would be written under
#'
#' Per the authority matrix: root writes the system sink (\code{"system"}); a
#' user-scope mutation writes the caller-owned sink (\code{"user"}); an
#' unprivileged system-scope mutation writes the caller-owned sink but is
#' honest that it is not system-durable (\code{"caller"}).
#'
#' @param scope \code{"system"} or \code{"user"}.
#' @param root Is the effective user root? (injectable; default detects.)
#' @return One of \code{"system"}, \code{"user"}, \code{"caller"}.
#' @examples
#' audit_scope_for("system", root = FALSE)
#' audit_scope_for("system", root = TRUE)
#' @export
audit_scope_for <- function(scope = c("system", "user"),
                            root = .euid_is_root()) {
    scope <- match.arg(scope)
    if (isTRUE(root)) {
        "system"
    } else if (identical(scope, "user")) {
        "user"
    } else {
        "caller"
    }
}

#' Is system-durable audit available on this host?
#'
#' True only when a mutation's audit can be written durably to the
#' root-owned system sink: the caller is root, or a privileged audit broker is
#' present. No broker exists yet, so this is root-only for now. A fleet policy
#' reads this to refuse system-scope mutations that would only be
#' caller-durably audited.
#'
#' @param root Is the effective user root? (injectable; default detects.)
#' @param broker Is the audit broker present? (default \code{FALSE}; no broker
#'   yet.)
#' @return \code{TRUE} or \code{FALSE}.
#' @examples
#' system_durable_audit_available(root = FALSE)
#' @export
system_durable_audit_available <- function(root = .euid_is_root(),
    broker = FALSE) {
    isTRUE(root) || isTRUE(broker)
}

#' Resolve the audit sink and its authority for a mutation scope
#'
#' Returns a ready sink plus the honest \code{audit_scope} and
#' \code{system_durable_audit} for this caller and scope (the authority
#' matrix). Path is deterministic and fails closed when it cannot be resolved.
#'
#' @param scope \code{"system"} or \code{"user"}.
#' @param root Is the effective user root? (injectable; default detects.)
#' @param xdg XDG state base for the caller-owned path (injectable).
#' @param system_dir Directory for the root-owned system sink.
#' @param ... Passed to \code{\link{file_audit_sink}} (e.g. \code{durability}).
#' @return \code{list(sink, path, audit_scope, system_durable_audit)}.
#' @examples
#' r <- default_audit_sink("user", root = FALSE,
#'     xdg = tempfile("xdg"), durability = "none")
#' r$audit_scope
#' @export
default_audit_sink <- function(scope = c("system", "user"),
                               root = .euid_is_root(),
                               xdg = .xdg_state_home(),
                               system_dir = "/var/log/runix", ...) {
    scope <- match.arg(scope)
    audit_scope <- audit_scope_for(scope, root)
    path <- if (identical(audit_scope, "system")) {
        file.path(system_dir, "audit.jsonl")
    } else {
        .xdg_audit_path(xdg)
    }
    list(sink = file_audit_sink(path, ...), path = path,
         audit_scope = audit_scope,
         system_durable_audit = system_durable_audit_available(root))
}
