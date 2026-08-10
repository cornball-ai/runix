## Durable audit sinks (durable-audit-contract.md). A sink is a small object
## with a `write(record)` method returning
## list(persisted = <logical>, durability = <chr>, ...). `persisted = TRUE`
## means the record reached storage at the requested durability and nothing
## else may set it true; a failed write returns FALSE and routes the record to
## the fallback channel, which never claims durability.

#' A file-backed, append-only JSONL audit sink
#'
#' Constructs the production audit sink: append-only JSONL, one record per
#' line, with an advisory lock around the append, optional `fsync`, size-based
#' rotation, restrictive permissions, and a symlink/world-writable refusal.
#' On any failure the record is routed to \code{fallback} and the write
#' reports \code{persisted = FALSE} (see durable-audit-contract.md).
#'
#' @param path Sink file path (system: \code{/var/log/runix/audit.jsonl};
#'   user: under \code{$XDG_STATE_HOME}). The directory is created if absent.
#' @param durability \code{"fsync"} (default; calls \code{syncer} and only
#'   then reports persisted), \code{"flush"} (flush to the OS, no fsync), or
#'   \code{"none"}.
#' @param max_bytes Rotate when the sink reaches this size (0/Inf disables).
#' @param keep Number of rotated files to retain (\code{audit.jsonl.1..N}).
#' @param dir_mode Permission mode enforced on the sink directory.
#' @param file_mode Permission mode enforced on the sink file.
#' @param lock_timeout Seconds to wait for the append lock before erroring.
#' @param lock_stale Age in seconds past which a lock whose owner is gone is
#'   considered stale and stolen.
#' @param encoder \code{function(record)} returning one JSON line (default
#'   \code{\link{encode_json_line}}; inject \code{yyjsonr} etc. if desired).
#' @param syncer \code{function(path)} that fsyncs the file, erroring on
#'   failure (default shells to coreutils \code{sync --data}).
#' @param dir_syncer \code{function(dir)} that fsyncs the parent directory
#'   after a create or rotation (default shells to coreutils \code{sync}), so
#'   the new/renamed entry is durable, not just the file's data.
#' @param fallback \code{function(record, reason)} best-effort emitter used
#'   when the primary write fails; must never claim durability.
#' @param id_fn \code{function()} minting a correlation id for a locally-owned
#'   record (injectable for deterministic tests). A remote broker mints ids
#'   itself, so its sink ignores this.
#' @param audit_scope The scope stamped on this sink's receipts
#'   (\code{"system"}/\code{"caller"}/\code{"user"}); \code{NA} if unset.
#' @param clock A clock function for record timestamps.
#' @return A sink implementing the receipt lifecycle:
#'   \code{open_intent(record) -> receipt},
#'   \code{write_outcome(receipt, record) -> status}, \code{emit(record,
#'   phase) -> receipt}, plus the low-level \code{write(record)} and
#'   \code{path}/\code{durability}/\code{audit_scope}/\code{kind}.
#' @examples
#' s <- file_audit_sink(tempfile(fileext = ".jsonl"), durability = "none")
#' s$write(list(operation = "demo", outcome = "ok"))$persisted
#' @export
file_audit_sink <- function(path, durability = c("fsync", "flush", "none"),
                            max_bytes = 10 * 1024 ^ 2, keep = 5L,
                            dir_mode = "0750", file_mode = "0640",
                            lock_timeout = 10, lock_stale = 60,
                            encoder = encode_json_line,
                            syncer = .default_syncer,
                            dir_syncer = .default_dir_syncer,
                            fallback = .default_fallback,
                            id_fn = new_correlation_id,
                            audit_scope = NA_character_, clock = sys_clock()) {
    durability <- match.arg(durability)
    force(path)
    force(encoder)
    force(syncer)
    force(dir_syncer)
    force(fallback)

    write <- function(record) {
        line <- tryCatch(encoder(record), error = function(e) e)
        if (inherits(line, "condition")) {
            fallback(record,
                     reason = paste0("encode failed: ", conditionMessage(line)))
            return(list(persisted = FALSE, durability = durability,
                        error = "encode_failed"))
        }
        res <- tryCatch(
                        .sink_append(path, line, durability, max_bytes, keep,
                                     dir_mode, file_mode, lock_timeout, lock_stale,
                                     syncer, dir_syncer),
                        error = function(e) e)
        if (inherits(res, "condition")) {
            fallback(record, reason = conditionMessage(res))
            return(list(persisted = FALSE, durability = durability,
                        error = conditionMessage(res)))
        }
        list(persisted = TRUE, durability = durability, path = path)
    }

    .local_lifecycle(
                     list(write = write, path = path, durability = durability,
                          kind = "file"),
                     id_fn, audit_scope, clock)
}

#' An in-memory audit sink for tests and consumers
#'
#' Records are appended to an in-memory list instead of a file. Useful for
#' testing consumers offline and for exercising failure handling: pass
#' \code{fail_on} to simulate a persistence failure for matching records.
#'
#' @param fail_on Optional \code{function(record)}; when it returns
#'   \code{TRUE}, that write reports \code{persisted = FALSE} and the record
#'   is not stored (as if the sink failed).
#' @param durability Reported durability label (default \code{"memory"}).
#' @param id_fn \code{function()} minting a correlation id (injectable for
#'   deterministic tests).
#' @param audit_scope The scope stamped on receipts; \code{NA} if unset.
#' @param clock A clock function for record timestamps.
#' @return A sink implementing the receipt lifecycle (see
#'   \code{\link{file_audit_sink}}) plus a \code{records()} accessor.
#' @examples
#' s <- memory_audit_sink()
#' s$write(list(outcome = "ok"))
#' length(s$records())
#' @export
memory_audit_sink <- function(fail_on = NULL, durability = "memory",
                              id_fn = new_correlation_id,
                              audit_scope = NA_character_,
                              clock = sys_clock()) {
    state <- new.env(parent = emptyenv())
    state$records <- list()
    write <- function(record) {
        if (!is.null(fail_on) && isTRUE(fail_on(record))) {
            return(list(persisted = FALSE, durability = durability,
                        error = "injected failure"))
        }
        state$records[[length(state$records) + 1L]] <- record
        list(persisted = TRUE, durability = durability)
    }
    records <- function() state$records
    .local_lifecycle(
                     list(write = write, records = records,
                          durability = durability, kind = "memory"),
                     id_fn, audit_scope, clock)
}

## Add the receipt-based lifecycle (open_intent / write_outcome / emit) to any
## sink exposing write(record). A local sink mints its own correlation ids
## (id_fn) and stamps its audit_scope on receipts; a remote broker sink
## implements this same interface differently (ids minted server-side, binding
## carried in the receipt), so consumers depend only on the interface.
.local_lifecycle <- function(base, id_fn, audit_scope, clock) {
    emit <- function(record, phase = "outcome", correlation_id = id_fn()) {
        res <- base$write(.finish_record(record, correlation_id, phase,
                clock()))
        list(correlation_id = correlation_id, persisted = isTRUE(res$persisted),
             audit_scope = audit_scope, binding = correlation_id,
             error = res$error)
    }
    open_intent <- function(record) emit(record, "intent")
    write_outcome <- function(receipt, record) {
        res <- base$write(.finish_record(record, receipt$correlation_id,
                "outcome", clock()))
        list(persisted = isTRUE(res$persisted), error = res$error)
    }
    c(base, list(open_intent = open_intent, write_outcome = write_outcome,
                 emit = emit, audit_scope = audit_scope))
}

## --- the append critical section -------------------------------------------

.sink_append <- function(path, line, durability, max_bytes, keep, dir_mode,
                         file_mode, lock_timeout, lock_stale, syncer,
                         dir_syncer) {
    created <- .ensure_sink_ready(path, dir_mode, file_mode)
    lock <- .acquire_lock(path, lock_timeout, lock_stale)
    on.exit(.release_lock(lock), add = TRUE)
    rotated <- .maybe_rotate(path, max_bytes, keep, file_mode)
    con <- file(path, open = "a", encoding = "UTF-8")
    tryCatch({
        writeLines(line, con, useBytes = TRUE)
        flush(con)
    }, finally = close(con))
    if (identical(durability, "fsync")) {
        syncer(path)
        ## fsync the directory entry too, but only when it changed (create or
        ## rotation); a plain append does not alter the parent directory.
        if (isTRUE(created) || isTRUE(rotated)) {
            dir_syncer(dirname(path))
        }
    }
    invisible(TRUE)
}

## Create the sink dir/file with restrictive perms; refuse a symlink or a
## world-writable sink (hijack guard).
.ensure_sink_ready <- function(path, dir_mode, file_mode) {
    created <- FALSE
    dir <- dirname(path)
    if (!dir.exists(dir)) {
        dir.create(dir, recursive = TRUE, mode = dir_mode)
        Sys.chmod(dir, mode = dir_mode, use_umask = FALSE)
    }
    if (!file.exists(path)) {
        old <- Sys.umask("0077")
        on.exit(Sys.umask(old), add = TRUE)
        if (!file.create(path, showWarnings = FALSE)) {
            runix_abort(paste0("cannot create audit sink: ", path),
                        subclass = "runix_audit_error",
                        data = list(resource = path))
        }
        Sys.chmod(path, mode = file_mode, use_umask = FALSE)
        created <- TRUE
    }
    if (nzchar(Sys.readlink(path))) {
        runix_abort(paste0("audit sink is a symlink, refusing to write: ", path),
                    subclass = "runix_audit_error",
                    data = list(resource = path))
    }
    mode <- file.info(path)$mode
    if (!is.na(mode) && bitwAnd(as.integer(mode), 2L) != 0L) {
        runix_abort(paste0("audit sink is world-writable, refusing to write: ",
                           path),
                    subclass = "runix_audit_error",
                    data = list(resource = path))
    }
    created
}

## --- advisory lock (mkdir is atomic), with stale-owner recovery ------------

.acquire_lock <- function(path, timeout, stale) {
    lockdir <- paste0(path, ".lock")
    waited <- 0
    interval <- 0.02
    repeat {
        if (dir.create(lockdir, showWarnings = FALSE)) {
            .write_lock_owner(lockdir)
            return(list(dir = lockdir))
        }
        if (.lock_is_stale(lockdir, stale)) {
            unlink(lockdir, recursive = TRUE, force = TRUE)
            next
        }
        if (waited >= timeout) {
            runix_abort(paste0("could not acquire audit lock within ",
                               timeout, "s: ", lockdir),
                        subclass = c("runix_audit_locked", "runix_audit_error"),
                        data = list(resource = path))
        }
        Sys.sleep(interval)
        waited <- waited + interval
        interval <- min(interval * 1.5, 0.5)
    }
}

.release_lock <- function(lock) {
    if (!is.null(lock) && !is.null(lock$dir)) {
        unlink(lock$dir, recursive = TRUE, force = TRUE)
    }
    invisible(NULL)
}

## A lock is stale if its recorded owner is provably gone, or (fallback) if
## the lock dir is older than `stale` seconds. Owner identity is pid + boot id
## + process start time, so a reboot (different boot id) or PID reuse (a live
## pid whose start time differs) is detected as a dead owner. Liveness/start
## time use /proc on Linux; where unavailable the answer is "unknown" and only
## the age test applies, so we never steal a fresh lock on non-Linux.
.lock_is_stale <- function(lockdir, stale) {
    owner <- .read_lock_owner(lockdir)
    if (!is.null(owner) && !is.na(owner$pid)) {
        cur_boot <- .boot_id()
        if (!is.na(cur_boot) && !is.na(owner$boot) &&
            !identical(cur_boot, owner$boot)) {
            return(TRUE) # machine rebooted since the lock was taken
        }
        alive <- .pid_alive(owner$pid)
        if (identical(alive, FALSE)) {
            return(TRUE)
        }
        if (identical(alive, TRUE)) {
            st <- .proc_starttime(owner$pid)
            if (!is.na(st) && !is.na(owner$starttime) &&
                !identical(st, owner$starttime)) {
                return(TRUE) # PID reused; the original owner is gone
            }
            return(FALSE) # genuinely held by a live owner
        }
        ## alive unknown (no /proc) -> fall through to the age test
    }
    info <- file.info(lockdir)
    if (is.na(info$mtime)) {
        return(FALSE)
    }
    age <- as.numeric(difftime(Sys.time(), info$mtime, units = "secs"))
    isTRUE(age > stale)
}

.pid_alive <- function(pid) {
    if (dir.exists("/proc")) {
        return(dir.exists(file.path("/proc", as.character(pid))))
    }
    NA
}

## Owner identity written into the lock: "pid boot starttime" on one line,
## with "-" for a value unavailable on this platform. boot id and start time
## contain no spaces, so a space split is unambiguous.
.write_lock_owner <- function(lockdir) {
    val <- paste(Sys.getpid(), .dash(.boot_id()),
                 .dash(.proc_starttime(Sys.getpid())))
    try(writeLines(val, file.path(lockdir, "owner")), silent = TRUE)
    invisible(NULL)
}

.read_lock_owner <- function(lockdir) {
    f <- file.path(lockdir, "owner")
    if (file.exists(f)) {
        line <- tryCatch(readLines(f, warn = FALSE)[1L],
                         error = function(e) NA_character_)
        if (!is.na(line)) {
            toks <- strsplit(line, " ", fixed = TRUE)[[1L]]
            if (length(toks) >= 3L) {
                return(list(
                            pid = suppressWarnings(as.integer(toks[1L])),
                            boot = if (identical(toks[2L], "-")) {
                            NA_character_
                        } else {
                            toks[2L]
                        },
                            starttime = if (identical(toks[3L], "-")) {
                            NA_character_
                        } else {
                            toks[3L]
                        }))
            }
        }
    }
    ## Legacy pid-only lock (pre-hardening): degrade to pid liveness alone.
    pf <- file.path(lockdir, "pid")
    if (file.exists(pf)) {
        pid <- suppressWarnings(as.integer(readLines(pf, warn = FALSE)[1L]))
        return(list(pid = pid, boot = NA_character_, starttime = NA_character_))
    }
    NULL
}

.dash <- function(x) {
    if (length(x) == 0L || is.na(x)) {
        "-"
    } else {
        as.character(x)
    }
}

## Boot id: stable per boot, changes on reboot. Linux only.
.boot_id <- function() {
    p <- "/proc/sys/kernel/random/boot_id"
    if (file.exists(p)) {
        tryCatch(readLines(p, warn = FALSE)[1L],
                 error = function(e) NA_character_)
    } else {
        NA_character_
    }
}

## Process start time (clock ticks since boot), field 22 of /proc/<pid>/stat.
## The comm field (2) may contain spaces and parens, so parse after the last
## ')': the remaining tokens start at field 3, so field 22 is token 20. Linux
## only.
.proc_starttime <- function(pid) {
    p <- file.path("/proc", as.character(pid), "stat")
    if (!file.exists(p)) {
        return(NA_character_)
    }
    line <- tryCatch(readLines(p, warn = FALSE)[1L],
                     error = function(e) NA_character_)
    if (is.na(line)) {
        return(NA_character_)
    }
    after <- sub("^.*\\) ", "", line)
    toks <- strsplit(after, " ", fixed = TRUE)[[1L]]
    if (length(toks) >= 20L) {
        toks[20L]
    } else {
        NA_character_
    }
}

## --- rotation: rename-then-create, never truncate-in-place ------------------

.maybe_rotate <- function(path, max_bytes, keep, file_mode) {
    if (!is.finite(max_bytes) || max_bytes <= 0) {
        return(FALSE)
    }
    if (!file.exists(path)) {
        return(FALSE)
    }
    sz <- file.info(path)$size
    if (is.na(sz) || sz < max_bytes) {
        return(FALSE)
    }
    oldest <- paste0(path, ".", keep)
    if (file.exists(oldest)) {
        unlink(oldest)
    }
    if (keep >= 2L) {
        for (i in seq.int(keep - 1L, 1L)) {
            src <- paste0(path, ".", i)
            if (file.exists(src)) {
                file.rename(src, paste0(path, ".", i + 1L))
            }
        }
    }
    file.rename(path, paste0(path, ".1"))
    old <- Sys.umask("0077")
    on.exit(Sys.umask(old), add = TRUE)
    file.create(path, showWarnings = FALSE)
    Sys.chmod(path, mode = file_mode, use_umask = FALSE)
    TRUE
}

## --- fsync and fallback -----------------------------------------------------

## Real fsync via coreutils `sync --data <file>` (fdatasync on the file's fd).
## Falls back to a bare `sync` (all filesystems) where `--data` is unsupported
## (BSD/macOS `sync` takes no options): coarser, but a genuine flush to stable
## storage. Errors only if neither works, so the caller can report
## persisted = FALSE honestly (e.g. on a host with no `sync` at all, like
## Windows, where fsync durability is simply unavailable).
.default_syncer <- function(path) {
    status <- suppressWarnings(
                               system2("sync", c("--data", shQuote(path)), stdout = FALSE,
                                       stderr = FALSE))
    if (identical(as.integer(status), 0L)) {
        return(invisible(TRUE))
    }
    status <- suppressWarnings(system2("sync", stdout = FALSE, stderr = FALSE))
    if (!identical(as.integer(status), 0L)) {
        stop("fsync via 'sync' failed for ", path, " (status ", status, ")")
    }
    invisible(TRUE)
}

## Full fsync of a directory (coreutils `sync <dir>`, not --data) so a created
## or renamed entry is durable. Errors on failure.
.default_dir_syncer <- function(dir) {
    status <- suppressWarnings(
                               system2("sync", shQuote(dir), stdout = FALSE, stderr = FALSE))
    if (!identical(as.integer(status), 0L)) {
        stop("directory fsync via 'sync' failed for ", dir, " (status ",
             status, ")")
    }
    invisible(TRUE)
}

## Best-effort emitter when the primary sink fails. Writes JSONL to stderr and
## tries the system logger. Never returns/represents durability.
.default_fallback <- function(record, reason = NULL) {
    line <- tryCatch(
                     encode_json_line(c(list(fallback = TRUE, reason = reason), record)),
                     error = function(e) "{\"fallback\":true,\"encode_error\":true}")
    cat(line, "\n", sep = "", file = stderr())
    try(system2("logger", c("-t", "runix-audit", shQuote(line)),
                stdout = FALSE, stderr = FALSE), silent = TRUE)
    invisible(FALSE)
}
