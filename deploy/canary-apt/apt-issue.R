# VM-ONLY canary launcher: drive the REAL pkgops issuer path for the §7 gates, in
# place of the rab-exercise oracle. Runs UNPRIVILEGED (as aptbot). It RECOMPUTES the
# preview itself via pkgops::apt_<verb>_preview() and treats the caller-supplied
# resource / plan_hash as EXPECTED values only -- compared byte-for-byte before any
# commit. It NEVER constructs or trusts a preview from caller hash data, and no
# receipt or binding ever enters argv, environment, disk, or this output (pkgops
# keeps those in the runix C heap and wipes them). It prints ONE `RESULT ...` line in
# the rab-exercise grammar and mirrors its exit codes: 0 = outcome durably persisted
# (incl. a valid refusal), 1 = pre-intent failure (nothing durable), 3 = intent LEFT
# OPEN (effect unknown). This file is NEVER packaged; install-apt-stack.sh stages and
# installs it only inside the disposable guest.

argv <- commandArgs(trailingOnly = TRUE)
if (length(argv) < 3L) {
    cat("apt-issue: usage: apt-issue <verb> <resource> <hash> [pkg...]\n",
        file = stderr())
    quit(status = 2L, save = "no")               # rab EX_USAGE, no RESULT line
}
verb <- argv[[1L]]
exp_resource <- argv[[2L]]
exp_hash <- argv[[3L]]
pkgs <- if (length(argv) > 3L) argv[-(1:3)] else character(0)

## verb -> (preview fn, commit fn). Whole-system verbs take no packages.
PREVIEW <- list(apt.install = pkgops::apt_install_preview,
                apt.remove = pkgops::apt_remove_preview,
                apt.purge = pkgops::apt_purge_preview,
                apt.hold = pkgops::apt_hold_preview,
                apt.unhold = pkgops::apt_unhold_preview,
                apt.update = pkgops::apt_update_preview,
                apt.upgrade = pkgops::apt_upgrade_preview,
                apt.dist_upgrade = pkgops::apt_dist_upgrade_preview,
                apt.configure = pkgops::apt_configure_preview)
COMMIT <- list(apt.install = pkgops::apt_install, apt.remove = pkgops::apt_remove,
               apt.purge = pkgops::apt_purge, apt.hold = pkgops::apt_hold,
               apt.unhold = pkgops::apt_unhold, apt.update = pkgops::apt_update,
               apt.upgrade = pkgops::apt_upgrade,
               apt.dist_upgrade = pkgops::apt_dist_upgrade,
               apt.configure = pkgops::apt_configure)
NULLARY <- c("apt.update", "apt.upgrade", "apt.dist_upgrade", "apt.configure")

if (is.null(PREVIEW[[verb]])) {
    cat(sprintf("apt-issue: unknown verb %s\n", verb), file = stderr())
    quit(status = 2L, save = "no")
}

## the CLOSED refusal statuses: at COMMIT time, a raised condition carrying one of
## these is a durably-persisted refusal (rab EX_OK / outcome=persisted). ok / no_op
## arrive on the RETURN path, never as a condition.
CLOSED <- c("held", "operation_failed", "apt_locked", "no_intent",
            "package_not_owned", "protected_package", "resolve_failed",
            "not_applied", "dpkg_broken", "internal",
            "unauthorized", "approval_required", "spawn_failed")

## the PREVIEW-side refusals: the ONLY statuses the read-only planner
## (apt_<verb>_preview()) legitimately raises as a policy refusal with no intent
## opened -- exactly the three the contract pins a plan digest to (besides `ok`).
## Any OTHER condition at preview time (resolve_failed, internal, a commit-only
## status leaking in, ...) has no committable intent and is a PRE-INTENT failure
## (exit 1), NOT a persisted refusal. This is deliberately NARROWER than CLOSED.
PREVIEW_REFUSED <- c("package_not_owned", "held", "protected_package")

## sanitize any value to a single RESULT token: the grammar is space-separated and
## unquoted, so a value with whitespace would corrupt the line. NULL/NA -> "".
tok <- function(x) {
    if (is.null(x) || length(x) != 1L || is.na(x)) {
        return("")
    }
    gsub("[[:space:]]+", "_", as.character(x))
}
## render effect_issued like rab-exercise: true / false / unknown (NA).
eff <- function(x) {
    if (is.null(x) || length(x) != 1L || is.na(x)) {
        return("unknown")
    }
    if (isTRUE(x)) "true" else "false"
}
## normalize a scalar for a byte-for-byte compare (NULL/NA -> "").
norm <- function(x) {
    if (is.null(x) || length(x) != 1L || is.na(x)) {
        ""
    } else {
        as.character(x)
    }
}
emit <- function(cid, plan_hash, status, detail, effect_issued, outcome) {
    cat(sprintf(paste("RESULT cid=%s plan_hash=%s verb=%s status=%s detail=%s",
                      "effect_issued=%s outcome=%s\n"),
                tok(cid), tok(plan_hash), verb, tok(status), tok(detail),
                effect_issued, outcome))
}

## --- 1. recompute the preview OURSELVES (never from caller hash data) ---------
prev <- tryCatch(if (verb %in% NULLARY) {
        PREVIEW[[verb]]()
    } else {
        PREVIEW[[verb]](pkgs)
    }, condition = function(c) c)
if (inherits(prev, "condition")) {
    ## a preview-side refusal or failure: NO intent is opened. ONLY the three genuine
    ## planner policy refusals (package_not_owned / held / protected_package) are
    ## meaningful, closed refusals -> emit with effect_issued=false and a
    ## preview_refused outcome, exit 0. EVERYTHING else at preview time
    ## (resolve_failed, internal, a commit-only status, a malformed reply) has no
    ## committable intent -> a PRE-INTENT failure, exit 1.
    st <- prev$status
    if (is.character(st) && length(st) == 1L && st %in% PREVIEW_REFUSED) {
        emit(prev$correlation_id, prev$plan_hash, st, prev$detail, "false",
             "preview_refused")
        quit(status = 0L, save = "no")
    }
    emit(prev$correlation_id, prev$plan_hash,
         if (is.character(st) && length(st) == 1L) st else "internal",
         conditionMessage(prev), "false", "no_intent")
    quit(status = 1L, save = "no")
}

## --- 2. compare the EXPECTED resource/hash byte-for-byte before committing. A
## mismatch means the caller's expectation disagrees with what pkgops independently
## planned: refuse, never commit a plan we did not derive ourselves.
if (!identical(norm(prev$resource), norm(exp_resource)) ||
    !identical(norm(prev$plan_hash), norm(exp_hash))) {
    emit(prev$correlation_id, prev$plan_hash, "expectation_mismatch",
         sprintf("expected %s/%s got %s/%s", norm(exp_resource),
                 substr(norm(exp_hash), 1L, 12L), norm(prev$resource),
                 substr(norm(prev$plan_hash), 1L, 12L)),
         "false", "refused")
    quit(status = 1L, save = "no")
}

## --- 3. commit the preview WE derived; map outcome / condition -> RESULT -------
oc <- tryCatch(COMMIT[[verb]](prev), condition = function(c) c)
if (!inherits(oc, "condition")) {
    ## success: a returned pkgops_outcome is always closed + durably written.
    emit(oc$correlation_id, oc$plan_hash, oc$status, NA, eff(oc$effect_issued),
         "persisted")
    quit(status = 0L, save = "no")
}
## a CLOSED refusal status -> the outcome was persisted before the raise; exit 0.
st <- oc$status
if (is.character(st) && length(st) == 1L && st %in% CLOSED) {
    emit(oc$correlation_id, oc$plan_hash, st, oc$detail, eff(oc$effect_issued),
         "persisted")
    quit(status = 0L, save = "no")
}
## otherwise post-open-left-open vs pre-intent, discriminated by the cid: pkgops now
## attaches the session cid to every left-open / effect-unknown condition, so a cid
## means an intent was opened and left OPEN (reconcilable), none means pre-intent.
cid <- oc$correlation_id
if (is.character(cid) && length(cid) == 1L && !is.na(cid) && nzchar(cid)) {
    emit(cid, oc$plan_hash, "unknown", "unknown", "unknown", "open")   # rab open line
    quit(status = 3L, save = "no")                                     # rab EX_OPEN_LEFT
}
cat(sprintf("apt-issue: %s\n", conditionMessage(oc)), file = stderr())
quit(status = 1L, save = "no")                                         # rab EX_FAIL
