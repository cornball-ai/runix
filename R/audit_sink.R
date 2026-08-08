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
#' @param fallback \code{function(record, reason)} best-effort emitter used
#'   when the primary write fails; must never claim durability.
#' @return A sink: \code{list(write, path, durability, kind)}.
#' @examples
#' s <- file_audit_sink(tempfile(fileext = ".jsonl"), durability = "none")
#' s$write(list(operation = "demo", outcome = "ok"))$persisted
#' @export
file_audit_sink <- function(path,
                            durability = c("fsync", "flush", "none"),
                            max_bytes = 10 * 1024^2,
                            keep = 5L,
                            dir_mode = "0750",
                            file_mode = "0640",
                            lock_timeout = 10,
                            lock_stale = 60,
                            encoder = encode_json_line,
                            syncer = .default_syncer,
                            fallback = .default_fallback) {
    durability <- match.arg(durability)
    force(path)
    force(encoder)
    force(syncer)
    force(fallback)

    write <- function(record) {
        line <- tryCatch(encoder(record), error = function(e) e)
        if (inherits(line, "condition")) {
            fallback(record, reason = paste0("encode failed: ",
                                             conditionMessage(line)))
            return(list(persisted = FALSE, durability = durability,
                        error = "encode_failed"))
        }
        res <- tryCatch(
                        .sink_append(path, line, durability, max_bytes, keep,
                                     dir_mode, file_mode, lock_timeout, lock_stale, syncer),
                        error = function(e) e)
        if (inherits(res, "condition")) {
            fallback(record, reason = conditionMessage(res))
            return(list(persisted = FALSE, durability = durability,
                        error = conditionMessage(res)))
        }
        list(persisted = TRUE, durability = durability, path = path)
    }

    list(write = write, path = path, durability = durability, kind = "file")
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
#' @return A sink with an extra \code{records()} accessor.
#' @examples
#' s <- memory_audit_sink()
#' s$write(list(outcome = "ok"))
#' length(s$records())
#' @export
memory_audit_sink <- function(fail_on = NULL, durability = "memory") {
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
    list(write = write, records = records, durability = durability,
         kind = "memory")
}

## --- the append critical section -------------------------------------------

.sink_append <- function(path, line, durability, max_bytes, keep, dir_mode,
                         file_mode, lock_timeout, lock_stale, syncer) {
    .ensure_sink_ready(path, dir_mode, file_mode)
    lock <- .acquire_lock(path, lock_timeout, lock_stale)
    on.exit(.release_lock(lock), add = TRUE)
    .maybe_rotate(path, max_bytes, keep, file_mode)
    con <- file(path, open = "a", encoding = "UTF-8")
    tryCatch({
        writeLines(line, con, useBytes = TRUE)
        flush(con)
    }, finally = close(con))
    if (identical(durability, "fsync")) {
        syncer(path)
    }
    invisible(TRUE)
}

## Create the sink dir/file with restrictive perms; refuse a symlink or a
## world-writable sink (hijack guard).
.ensure_sink_ready <- function(path, dir_mode, file_mode) {
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
    invisible(TRUE)
}

## --- advisory lock (mkdir is atomic), with stale-owner recovery ------------

.acquire_lock <- function(path, timeout, stale) {
    lockdir <- paste0(path, ".lock")
    waited <- 0
    interval <- 0.02
    repeat {
        if (dir.create(lockdir, showWarnings = FALSE)) {
            try(writeLines(as.character(Sys.getpid()),
                           file.path(lockdir, "pid")), silent = TRUE)
            return(list(dir = lockdir))
        }
        if (.lock_is_stale(lockdir, stale)) {
            unlink(lockdir, recursive = TRUE, force = TRUE)
            next
        }
        if (waited >= timeout) {
            runix_abort(paste0("could not acquire audit lock within ", timeout,
                               "s: ", lockdir),
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

## A lock is stale if its recorded owner pid is provably gone, or (fallback)
## if the lock dir is older than `stale` seconds. Pid-liveness uses /proc on
## Linux; where that is unavailable the answer is "unknown" and only the age
## test applies, so we never steal a fresh lock on non-Linux.
.lock_is_stale <- function(lockdir, stale) {
    pidfile <- file.path(lockdir, "pid")
    if (file.exists(pidfile)) {
        pid <- suppressWarnings(as.integer(readLines(pidfile, warn = FALSE)[1L]))
        if (!is.na(pid) && identical(.pid_alive(pid), FALSE)) {
            return(TRUE)
        }
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

## --- rotation: rename-then-create, never truncate-in-place ------------------

.maybe_rotate <- function(path, max_bytes, keep, file_mode) {
    if (!is.finite(max_bytes) || max_bytes <= 0) {
        return(invisible())
    }
    if (!file.exists(path)) {
        return(invisible())
    }
    sz <- file.info(path)$size
    if (is.na(sz) || sz < max_bytes) {
        return(invisible())
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
    invisible()
}

## --- fsync and fallback -----------------------------------------------------

## Real fsync via coreutils `sync --data <file>` (fdatasync on the file's fd).
## Errors on failure so the caller can report persisted = FALSE honestly.
.default_syncer <- function(path) {
    status <- suppressWarnings(
                               system2("sync", c("--data", shQuote(path)),
                                       stdout = FALSE, stderr = FALSE))
    if (!identical(as.integer(status), 0L)) {
        stop("fsync via 'sync' failed for ", path, " (status ", status, ")")
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
