# Canary-only P4 probe. The real public API must refuse in machine mode before
# opening an effect session. Keep the real planner, pkcheck, capability and plain
# refusal audit; replace only effect-session open with a fail-closed tripwire.
# This never proves the authorized commit path (the later gates do that).
machine_refusal <- function() {
    set_ops <- getFromNamespace("set_session_ops", "pkgops")
    ops <- getFromNamespace("session_ops", "pkgops")()
    opened <- FALSE
    ops$open <- function(...) {
        opened <<- TRUE
        stop("P4 attempted to open an effect session", call. = FALSE)
    }
    old <- set_ops(ops)
    on.exit(set_ops(old), add = TRUE)

    preview <- pkgops::apt_install_preview("canary-benign")
    result <- tryCatch(pkgops::apt_install(preview, interactive = FALSE),
                       error = identity)
    if (opened) {
        stop("P4 authorization did not refuse before effect-session open",
             call. = FALSE)
    }
    status <- result$status
    cid <- result$correlation_id
    valid <- inherits(result, "runix_unauthorized") ||
        inherits(result, "runix_approval_required")
    if (!valid || !is.character(status) || length(status) != 1L ||
        is.na(status) || !status %in% c("unauthorized", "approval_required") ||
        !identical(result$effect_issued, FALSE) ||
        !is.character(cid) || length(cid) != 1L || is.na(cid) ||
        !grepl("^[A-Za-z0-9_-]+$", cid)) {
        stop("P4 did not return a typed, correlated, effect-free refusal",
             call. = FALSE)
    }
    cat(sprintf("MACHINE_REFUSAL cid=%s status=%s effect_issued=false effect_session_opened=false\n",
                cid, status))
    invisible(result)
}

if (sys.nframe() == 0L) machine_refusal()
