## Durable-audit sink and two-phase driver: append correctness, permissions,
## fsync, rotation, and every failure/crash path the contract names.

silent_fb <- function(record, reason) invisible(FALSE)

td <- tempfile("runix-audit-")
dir.create(td)

## --- file sink: append-only, one line per record, honest persisted ---
sp <- file.path(td, "audit.jsonl")
s <- file_audit_sink(sp, durability = "none")
expect_true(s$write(list(operation = "demo", outcome = "ok"))$persisted)
expect_true(s$write(list(operation = "demo2", outcome = "ok"))$persisted)
lines <- readLines(sp, warn = FALSE)
expect_equal(length(lines), 2L)
expect_true(all(grepl("^\\{.*\\}$", lines)))

## actor is sink-stamped framing on the FRAMED audit path (emit / two-phase),
## not the bare write() primitive: the sink adds a normalized "uid:N" the
## caller's record never carried (durable-audit-contract.md). This is what lets
## a subsystem hand the SAME record to the broker, which derives actor from
## SO_PEERCRED and rejects a client-supplied one.
ep <- file.path(td, "framed.jsonl")
se <- file_audit_sink(ep, durability = "none")
expect_true(se$emit(list(operation = "demo", outcome = "preview"),
                    "preview")$persisted)
fr <- janssonr::from_json(readLines(ep, warn = FALSE)[1L])
expect_true(grepl("^uid:", fr$actor))
expect_identical(fr$operation, "demo")

## file perms restrictive: not world-readable, not world-writable (0640)
m <- as.integer(file.info(sp)$mode)
expect_equal(bitwAnd(m, 2L), 0L)
expect_equal(bitwAnd(m, 4L), 0L)

## --- symlink sink refused (hijack guard) ---
linkp <- file.path(td, "link.jsonl")
file.symlink(sp, linkp)
sl <- file_audit_sink(linkp, durability = "none", fallback = silent_fb)
expect_false(sl$write(list(x = 1))$persisted)

## --- world-writable sink refused ---
wp <- file.path(td, "ww.jsonl")
file.create(wp)
Sys.chmod(wp, "0666", use_umask = FALSE)   # actually world-writable
sw <- file_audit_sink(wp, durability = "none", fallback = silent_fb)
expect_false(sw$write(list(x = 1))$persisted)

## --- fsync durability: syncer runs; a failing syncer -> not persisted ---
calls <- new.env()
calls$n <- 0L
okp <- file.path(td, "fsync.jsonl")
sf <- file_audit_sink(okp, durability = "fsync",
                      syncer = function(p) {
                          calls$n <- calls$n + 1L
                          invisible(TRUE)
                      })
expect_true(sf$write(list(x = 1))$persisted)
expect_equal(calls$n, 1L)

badp <- file.path(td, "fsyncbad.jsonl")
sb <- file_audit_sink(badp, durability = "fsync",
                      syncer = function(p) stop("disk gone"),
                      fallback = silent_fb)
expect_false(sb$write(list(x = 1))$persisted)

## --- rotation: rename-then-create; retained records intact, none torn ---
rp <- file.path(td, "rot.jsonl")
sr <- file_audit_sink(rp, durability = "none", max_bytes = 200, keep = 100L)
for (i in 1:50) {
    expect_true(sr$write(list(i = i, pad = strrep("x", 20)))$persisted)
}
expect_true(file.exists(paste0(rp, ".1")))            # rotation happened
files <- c(rp, Sys.glob(paste0(rp, ".*")))
total <- sum(vapply(files, function(f) length(readLines(f, warn = FALSE)),
                    integer(1)))
expect_equal(total, 50L)                              # nothing lost (keep large)
ivals <- sort(unlist(lapply(files, function(f) {
    ls <- readLines(f, warn = FALSE)
    as.integer(sub('.*"i":([0-9]+).*', "\\1", ls))
})))
expect_equal(ivals, 1:50)                            # every record recoverable

## retention is bounded: keep = 2 -> at most current + 2 rotated files
rp2 <- file.path(td, "rot2.jsonl")
sr2 <- file_audit_sink(rp2, durability = "none", max_bytes = 200, keep = 2L)
for (i in 1:50) sr2$write(list(i = i, pad = strrep("x", 20)))
expect_true(length(c(rp2, Sys.glob(paste0(rp2, ".*")))) <= 3L)

## --- memory sink + injected failure ---
ms <- memory_audit_sink()
expect_true(ms$write(list(a = 1))$persisted)
expect_equal(length(ms$records()), 1L)
## memory sink stamps the normalized actor framing on the emit/two-phase path
me <- memory_audit_sink()
me$emit(list(operation = "x", outcome = "preview"), "preview")
expect_true(grepl("^uid:", me$records()[[1L]]$actor))
mf <- memory_audit_sink(fail_on = function(r) identical(r$phase, "outcome"))
expect_false(mf$write(list(phase = "outcome"))$persisted)

## --- two-phase: intent then outcome, shared correlation_id, persisted ---
ts <- memory_audit_sink()
ran <- new.env()
ran$effect <- FALSE
out <- audit_two_phase(ts,
    intent = list(operation = "demo.op", effect_issued = FALSE,
                  outcome = "intent"),
    effect = function(cid) {
        ran$effect <- TRUE
        list(cid = cid, ok = TRUE)
    },
    outcome = function(r) list(operation = "demo.op", effect_issued = TRUE,
                               outcome = "ok"))
expect_true(ran$effect)
expect_true(out$audit_persisted)
recs <- ts$records()
expect_equal(length(recs), 2L)
expect_equal(recs[[1]]$phase, "intent")
expect_equal(recs[[2]]$phase, "outcome")
expect_equal(recs[[1]]$correlation_id, recs[[2]]$correlation_id)
expect_equal(out$correlation_id, recs[[1]]$correlation_id)  # sink-minted, shared

## --- fail-closed: intent not durable -> effect NOT issued, raises ---
fc <- memory_audit_sink(fail_on = function(r) identical(r$phase, "intent"))
ran2 <- new.env()
ran2$effect <- FALSE
expect_error(
    audit_two_phase(fc,
        intent = list(operation = "x", outcome = "intent"),
        effect = function(cid) {
            ran2$effect <- TRUE
            list()
        },
        outcome = function(r) list(outcome = "ok")),
    "not durable")
expect_false(ran2$effect)

## --- degrade: intent fails, effect still runs, audit_persisted FALSE ---
dg <- memory_audit_sink(fail_on = function(r) identical(r$phase, "intent"))
ran3 <- new.env()
ran3$effect <- FALSE
outd <- audit_two_phase(dg,
    intent = list(operation = "x", outcome = "intent"),
    effect = function(cid) {
        ran3$effect <- TRUE
        list()
    },
    outcome = function(r) list(outcome = "ok"),
    on_intent_failure = "degrade")
expect_true(ran3$effect)
expect_false(outd$intent_persisted)
expect_true(outd$outcome_persisted)
expect_false(outd$audit_persisted)

## --- outcome-write failure: effect issued, audit_persisted FALSE ---
of <- memory_audit_sink(fail_on = function(r) identical(r$phase, "outcome"))
outo <- audit_two_phase(of,
    intent = list(operation = "x", outcome = "intent"),
    effect = function(cid) list(ok = TRUE),
    outcome = function(r) list(outcome = "ok"))
expect_true(outo$intent_persisted)
expect_false(outo$outcome_persisted)
expect_false(outo$audit_persisted)

## --- effect error -> error outcome record written, then re-raised ---
ee <- memory_audit_sink()
expect_error(
    audit_two_phase(ee,
        intent = list(operation = "x", outcome = "intent"),
        effect = function(cid) stop("boom"),
        outcome = function(r) list(outcome = "ok")),
    "boom")
recs2 <- ee$records()
expect_equal(length(recs2), 2L)
expect_equal(recs2[[2]]$phase, "outcome")
expect_equal(recs2[[2]]$outcome, "error")

## --- crash gap: intent persisted, process dies before outcome ->
##     an open intent is queryable on disk (not a silent effect) ---
gp <- file.path(td, "gap.jsonl")
gs <- file_audit_sink(gp, durability = "none")
gs$write(list(schema_version = 1L, correlation_id = "cid-crash",
              phase = "intent", operation = "z"))
if (requireNamespace("janssonr", quietly = TRUE)) {
    recs3 <- lapply(readLines(gp, warn = FALSE), janssonr::from_json)
    intents <- Filter(function(r) identical(r$phase, "intent"), recs3)
    outcomes <- Filter(function(r) identical(r$phase, "outcome"), recs3)
    open_ids <- setdiff(
        vapply(intents, function(r) r$correlation_id, character(1)),
        vapply(outcomes, function(r) r$correlation_id, character(1)))
    expect_true("cid-crash" %in% open_ids)
}

## --- stale lock (dead owner) is stolen so a live writer proceeds ---
lp <- file.path(td, "lock.jsonl")
file.create(lp)
lockdir <- paste0(lp, ".lock")
dir.create(lockdir)
writeLines("999999999", file.path(lockdir, "pid"))   # a pid that is not alive
sl2 <- file_audit_sink(lp, durability = "none", lock_timeout = 3,
                       lock_stale = 3600)             # mtime path won't fire
expect_true(sl2$write(list(x = 1))$persisted)         # stole the dead-owner lock

## --- reboot detection: an owner from a different boot is stale -> stolen ---
if (file.exists("/proc/sys/kernel/random/boot_id")) {
    lb <- file.path(td, "bootlock.jsonl")
    file.create(lb)
    ldb <- paste0(lb, ".lock")
    dir.create(ldb)
    writeLines(paste(Sys.getpid(),
                     "00000000-0000-0000-0000-000000000000", "1"),
               file.path(ldb, "owner"))              # different boot id
    sboot <- file_audit_sink(lb, durability = "none", lock_timeout = 3,
                             lock_stale = 3600)
    expect_true(sboot$write(list(x = 1))$persisted)
}

## --- PID reuse: live pid but wrong start time is stale -> stolen ---
if (dir.exists(file.path("/proc", Sys.getpid()))) {
    lr <- file.path(td, "reuselock.jsonl")
    file.create(lr)
    ldr <- paste0(lr, ".lock")
    dir.create(ldr)
    writeLines(paste(Sys.getpid(), "-", "1"),        # bogus start time
               file.path(ldr, "owner"))
    sreuse <- file_audit_sink(lr, durability = "none", lock_timeout = 3,
                              lock_stale = 3600)
    expect_true(sreuse$write(list(x = 1))$persisted)
}

## --- a genuinely live owner (correct pid+boot+start time) is NOT stolen ---
ll <- file.path(td, "livelock.jsonl")
file.create(ll)
ldl <- paste0(ll, ".lock")
dir.create(ldl)
runix:::.write_lock_owner(ldl)                        # this live process
slive <- file_audit_sink(ll, durability = "none", lock_timeout = 1,
                         lock_stale = 3600, fallback = silent_fb)
expect_false(slive$write(list(x = 1))$persisted)      # live owner respected

## --- parent directory is fsync'd on create/rotation, not on plain append ---
dcalls <- new.env()
dcalls$file <- 0L
dcalls$dir <- 0L
dp <- file.path(td, "dirsync.jsonl")
sd <- file_audit_sink(dp, durability = "fsync",
    syncer = function(p) {
        dcalls$file <- dcalls$file + 1L
        invisible(TRUE)
    },
    dir_syncer = function(d) {
        dcalls$dir <- dcalls$dir + 1L
        invisible(TRUE)
    })
sd$write(list(x = 1))                                 # creates -> dir fsync
expect_equal(dcalls$dir, 1L)
expect_equal(dcalls$file, 1L)
sd$write(list(x = 2))                                 # append only -> no dir fsync
expect_equal(dcalls$dir, 1L)
expect_equal(dcalls$file, 2L)

## --- multi-process concurrency: no torn/interleaved lines under contention ---
## Local only (needs littler + installed runix); skipped during R CMD check.
if (at_home() && nzchar(Sys.which("r"))) {
    cp <- file.path(td, "concurrent.jsonl")
    file.create(cp)
    script <- tempfile(fileext = ".R")
    writeLines(sprintf(paste0(
        'suppressMessages(library(runix)); ',
        's <- file_audit_sink("%s", durability = "flush"); ',
        'for (i in 1:30) s$write(list(w = Sys.getpid(), i = i, ',
        'pad = strrep("y", 30)))'), cp), script)
    for (k in 1:3) {
        system2("r", shQuote(script), wait = FALSE, stdout = FALSE,
                stderr = FALSE)
    }
    deadline <- Sys.time() + 20
    repeat {
        n <- length(readLines(cp, warn = FALSE))
        if (n >= 90L || Sys.time() > deadline) break
        Sys.sleep(0.2)
    }
    got <- readLines(cp, warn = FALSE)
    expect_equal(length(got), 90L)                    # nothing lost
    expect_true(all(grepl("^\\{.*\\}$", got)))        # no torn/interleaved lines
    if (requireNamespace("janssonr", quietly = TRUE)) {
        expect_silent(lapply(got, janssonr::from_json))  # every line parses
    }
}

## --- audit_emit: one framed record with the shared correlation id ---
me <- memory_audit_sink()
re <- audit_emit(me, list(operation = "demo", outcome = "preview"),
                 phase = "preview", correlation_id = "cid-1")
expect_true(re$persisted)
expect_equal(re$correlation_id, "cid-1")
rec <- me$records()[[1]]
expect_equal(rec$phase, "preview")
expect_equal(rec$correlation_id, "cid-1")
expect_equal(rec$schema_version, 1L)
expect_equal(rec$record_type, "audit")
expect_false(is.null(rec$host))
expect_false(is.null(rec$pid))
expect_false(is.null(rec$time))

## --- audit_two_phase on_error: rich error outcome + cid on the condition ---
oe <- memory_audit_sink(id_fn = function() "cid-oe")   # sink mints the id now
cond <- tryCatch(
    audit_two_phase(oe,
        intent = list(operation = "x", outcome = "intent"),
        effect = function(cid) runix_abort("boom", subclass = "demo_timeout",
                                           data = list(observed = "activating")),
        outcome = function(r) list(outcome = "ok"),
        on_error = function(e, cid) list(outcome = "timeout",
                                         effect_issued = TRUE,
                                         observed = e$observed)),
    condition = function(c) c)
expect_inherits(cond, "demo_timeout")             # original class survives
expect_equal(cond$observed, "activating")         # original data survives
expect_equal(cond$correlation_id, "cid-oe")       # cid attached to the error
recs_oe <- oe$records()
expect_equal(recs_oe[[1]]$phase, "intent")
expect_equal(recs_oe[[2]]$phase, "outcome")
expect_equal(recs_oe[[2]]$outcome, "timeout")     # rich, typed error outcome
expect_equal(recs_oe[[2]]$observed, "activating")

## --- authority resolution ---
expect_equal(audit_scope_for("system", root = TRUE), "system")
expect_equal(audit_scope_for("system", root = FALSE), "caller")
expect_equal(audit_scope_for("user", root = FALSE), "user")
expect_true(system_durable_audit_available(root = TRUE))
## unprivileged availability is a runtime root-authenticated probe, not a
## Boolean: no reachable broker -> FALSE. The available/untrusted cases are
## exercised against a real/fake broker in test_broker_sink.R.
expect_false(system_durable_audit_available(root = FALSE,
    socket_path = tempfile(fileext = ".sock")))

## --- receipt-based lifecycle: open_intent / write_outcome / emit ---
ls <- memory_audit_sink(id_fn = function() "cid-life", audit_scope = "caller")
rcpt <- ls$open_intent(list(operation = "demo.op", outcome = "intent"))
expect_equal(rcpt$correlation_id, "cid-life")
expect_true(rcpt$persisted)
expect_equal(rcpt$audit_scope, "caller")
st <- ls$write_outcome(rcpt, list(operation = "demo.op", outcome = "ok"))
expect_true(st$persisted)
lrecs <- ls$records()
expect_equal(length(lrecs), 2L)
expect_equal(lrecs[[1]]$phase, "intent")
expect_equal(lrecs[[2]]$phase, "outcome")
expect_equal(lrecs[[1]]$correlation_id, "cid-life")
expect_equal(lrecs[[2]]$correlation_id, "cid-life")  # outcome bound to receipt

## emit mints a fresh id for a single non-effect record
es <- memory_audit_sink()
r1 <- es$emit(list(operation = "p", outcome = "preview"), "preview")
expect_equal(es$records()[[1]]$phase, "preview")
expect_false(is.null(r1$correlation_id))

## the file sink implements the same interface
fp <- file.path(td, "lifecycle.jsonl")
fsk <- file_audit_sink(fp, durability = "none", audit_scope = "caller",
                       id_fn = function() "cid-file")
fr <- fsk$open_intent(list(operation = "op", outcome = "intent"))
expect_equal(fr$correlation_id, "cid-file")
expect_equal(fr$audit_scope, "caller")
fsk$write_outcome(fr, list(operation = "op", outcome = "ok"))
fl <- readLines(fp, warn = FALSE)
expect_equal(length(fl), 2L)
expect_true(all(grepl("cid-file", fl)))

## unprivileged system-scope -> caller-owned sink, honest about durability
xdg <- file.path(td, "xdg")
r_sys <- default_audit_sink("system", root = FALSE, xdg = xdg,
                            broker_socket = tempfile(fileext = ".sock"),
                            durability = "none")
expect_equal(r_sys$audit_scope, "caller")
expect_false(r_sys$system_durable_audit)
expect_true(grepl("runix/audit\\.jsonl$", r_sys$path))
expect_true(r_sys$sink$write(list(operation = "x", outcome = "ok"))$persisted)
expect_true(file.exists(r_sys$path))

r_usr <- default_audit_sink("user", root = FALSE, xdg = xdg, durability = "none")
expect_equal(r_usr$audit_scope, "user")

r_root <- default_audit_sink("system", root = TRUE,
                             system_dir = file.path(td, "sysroot"),
                             durability = "none")
expect_equal(r_root$audit_scope, "system")
expect_true(r_root$system_durable_audit)

## XDG resolution fails closed when there is no base to resolve
expect_error(runix:::.xdg_audit_path(""), "cannot resolve")
