# Hermetic controls for the actual P4 probe. No planner, polkit, broker, effect
# session or dpkg process may run. Invoke with Rscript --vanilla <file> <probe>.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 1L)
source(args[[1L]])
cat("pkgops", as.character(packageVersion("pkgops")),
    getNamespaceInfo(asNamespace("pkgops"), "path"), "\n")

check_probe <- function(rc, persisted = TRUE) {
    set_ops <- getFromNamespace("set_session_ops", "pkgops")
    set_pk <- getFromNamespace("set_pkcheck", "pkgops")
    set_runner <- getFromNamespace("set_runner", "pkgops")
    calls <- character()
    tripwire <- function(...) stop("UNEXPECTED real-effect operation")
    ops <- list(
        capability = function(...) calls <<- c(calls, "capability"),
        open = tripwire, commit = tripwire, write_outcome = tripwire,
        refuse = function(socket_path, operation, resource, status, ...) {
            calls <<- c(calls, "refuse")
            stopifnot(operation == "apt.install", resource == "canary-benign",
                      status %in% c("unauthorized", "approval_required"))
            list(correlation_id = "20260919000000000000-0123456789abcdef",
                 audit_persisted = persisted)
        })
    old_ops <- set_ops(ops)
    on.exit(set_ops(old_ops), add = TRUE)
    old_pk <- set_pk(function(action) {
        stopifnot(action == "ai.cornball.runix.apt.install")
        calls <<- c(calls, "pkcheck")
        rc
    })
    on.exit(set_pk(old_pk), add = TRUE)
    old_runner <- set_runner(function(cmd, args, input) {
        calls <<- c(calls, "preview")
        request <- janssonr::from_json(input)
        stopifnot(request$verb == "apt.install",
                  identical(request$packages, list("canary-benign")))
        json <- sprintf(paste0('{"schema_version":1,"status":"ok",',
            '"verb":"apt.install","packages":["canary-benign"],',
            '"plan_schema":1,"resource":"canary-benign",',
            '"plan_hash":"%s","records":[],"detail":null}'), strrep("b", 64L))
        list(status = 0L, output = json, stderr = character())
    })
    on.exit(set_runner(old_runner), add = TRUE)
    output <- capture.output(result <- tryCatch(machine_refusal(), error = identity))
    stopifnot(identical(getFromNamespace("session_ops", "pkgops")(), ops))
    if (rc %in% c(1L, 2L) && persisted) {
        stopifnot(length(output) == 1L, startsWith(output, "MACHINE_REFUSAL "),
                  identical(result$effect_issued, FALSE),
                  identical(calls, c("preview", "capability", "pkcheck", "refuse")))
    } else {
        stopifnot(inherits(result, "error"), length(output) == 0L)
        expected <- c("preview", "capability", "pkcheck")
        if (rc == 2L) expected <- c(expected, "refuse")
        stopifnot(identical(calls, expected))
        if (rc == 0L) {
            stopifnot(grepl("before effect-session open", conditionMessage(result), fixed = TRUE))
        }
    }
    cat("PASS machine refusal rc=", rc, " persisted=", persisted, "\n", sep = "")
}
check_probe(1L)
check_probe(2L)
check_probe(0L) # Authorized negative control must hit the probe's open tripwire.
check_probe(127L) # Missing tool must not pass as a refusal.
check_probe(2L, FALSE) # Refusal without durable audit must not pass.
cat("5 machine-refusal checks passed\n")
