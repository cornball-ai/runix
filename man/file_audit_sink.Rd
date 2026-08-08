% tinyrox says don't edit this manually, but it can't stop you!
\name{file_audit_sink}
\alias{file_audit_sink}
\title{A file-backed, append-only JSONL audit sink}
\usage{
file_audit_sink(
  path,
  durability = c("fsync", "flush", "none"),
  max_bytes = 10 * 1024^2,
  keep = 5L,
  dir_mode = "0750",
  file_mode = "0640",
  lock_timeout = 10,
  lock_stale = 60,
  encoder = encode_json_line,
  syncer = .default_syncer,
  fallback = .default_fallback
)
}
\arguments{
\item{path}{Sink file path (system: \code{/var/log/runix/audit.jsonl};
user: under \code{$XDG_STATE_HOME}). The directory is created if absent.}

\item{durability}{\code{"fsync"} (default; calls \code{syncer} and only
then reports persisted), \code{"flush"} (flush to the OS, no fsync), or
\code{"none"}.}

\item{max_bytes}{Rotate when the sink reaches this size (0/Inf disables).}

\item{keep}{Number of rotated files to retain (\code{audit.jsonl.1..N}).}

\item{dir_mode}{Permission mode enforced on the sink directory.}

\item{file_mode}{Permission mode enforced on the sink file.}

\item{lock_timeout}{Seconds to wait for the append lock before erroring.}

\item{lock_stale}{Age in seconds past which a lock whose owner is gone is
considered stale and stolen.}

\item{encoder}{\code{function(record)} returning one JSON line (default
\code{\link{encode_json_line}}; inject \code{yyjsonr} etc. if desired).}

\item{syncer}{\code{function(path)} that fsyncs the file, erroring on
failure (default shells to coreutils \code{sync --data}).}

\item{fallback}{\code{function(record, reason)} best-effort emitter used
when the primary write fails; must never claim durability.}
}
\value{
A sink: \code{list(write, path, durability, kind)}.
}
\description{
Constructs the production audit sink: append-only JSONL, one record per
line, with an advisory lock around the append, optional `fsync`, size-based
rotation, restrictive permissions, and a symlink/world-writable refusal.
On any failure the record is routed to \code{fallback} and the write
reports \code{persisted = FALSE} (see durable-audit-contract.md).
}
\examples{
s <- file_audit_sink(tempfile(fileext = ".jsonl"), durability = "none")
s$write(list(operation = "demo", outcome = "ok"))$persisted
}
