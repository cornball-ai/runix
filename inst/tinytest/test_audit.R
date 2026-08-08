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
                               outcome = "ok"),
    id_fn = function() new_correlation_id(counter = 7L))
expect_true(ran$effect)
expect_true(out$audit_persisted)
recs <- ts$records()
expect_equal(length(recs), 2L)
expect_equal(recs[[1]]$phase, "intent")
expect_equal(recs[[2]]$phase, "outcome")
expect_equal(recs[[1]]$correlation_id, recs[[2]]$correlation_id)

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
        outcome = function(r) list(outcome = "ok"),
        id_fn = function() new_correlation_id(counter = 1L)),
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
    on_intent_failure = "degrade",
    id_fn = function() new_correlation_id(counter = 2L))
expect_true(ran3$effect)
expect_false(outd$intent_persisted)
expect_true(outd$outcome_persisted)
expect_false(outd$audit_persisted)

## --- outcome-write failure: effect issued, audit_persisted FALSE ---
of <- memory_audit_sink(fail_on = function(r) identical(r$phase, "outcome"))
outo <- audit_two_phase(of,
    intent = list(operation = "x", outcome = "intent"),
    effect = function(cid) list(ok = TRUE),
    outcome = function(r) list(outcome = "ok"),
    id_fn = function() new_correlation_id(counter = 3L))
expect_true(outo$intent_persisted)
expect_false(outo$outcome_persisted)
expect_false(outo$audit_persisted)

## --- effect error -> error outcome record written, then re-raised ---
ee <- memory_audit_sink()
expect_error(
    audit_two_phase(ee,
        intent = list(operation = "x", outcome = "intent"),
        effect = function(cid) stop("boom"),
        outcome = function(r) list(outcome = "ok"),
        id_fn = function() new_correlation_id(counter = 4L)),
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
if (requireNamespace("jsonlite", quietly = TRUE)) {
    recs3 <- lapply(readLines(gp, warn = FALSE), jsonlite::fromJSON)
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
    if (requireNamespace("jsonlite", quietly = TRUE)) {
        expect_silent(lapply(got, jsonlite::fromJSON))  # every line parses
    }
}
