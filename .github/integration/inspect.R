## Integration gate, root-inspector half. The root-owned sink was copied out by
## `sudo cat` (root read) into a runner-readable file, with its owner/mode
## recorded separately; this parses that copy and verifies the durable record.
lib <- Sys.getenv("R_LIBS_INTEGRATION")
if (nzchar(lib)) {
    .libPaths(lib)
}
cid <- readLines("/tmp/rab-cid.txt")[1]
uid <- as.integer(Sys.getenv("RAB_CLIENT_UID"))
stopifnot(nzchar(cid), is.finite(uid))

lines <- readLines("/tmp/rab-sink-copy.jsonl", warn = FALSE)
recs <- Filter(Negate(is.null),
               lapply(lines, function(l) {
                   tryCatch(yyjsonr::read_json_str(l), error = function(e) NULL)
               }))
mine <- Filter(function(r) identical(r$record_type, "audit") &&
                   identical(r$correlation_id, cid), recs)

## matching correlation id across exactly the intent + outcome pair
phases <- sort(vapply(mine, function(r) as.character(r$phase), ""))
stopifnot(identical(phases, c("intent", "outcome")))

## every record carries the UNPRIVILEGED caller's kernel-verified identity, not
## the root broker's; the top-level pid agrees with broker.peer.pid.
for (r in mine) {
    stopifnot(identical(r$actor, paste0("uid:", uid)),
              identical(as.integer(r$broker$peer$uid), uid),
              identical(as.integer(r$pid), as.integer(r$broker$peer$pid)),
              !is.null(r$broker$peer$boot_id), !is.null(r$broker$peer$starttime))
}

## the sink is root-owned and mode 0640 (from the root stat)
own <- strsplit(readLines("/tmp/rab-sink-perms.txt")[1], " ", fixed = TRUE)[[1]]
stopifnot(identical(own[1], "root"), identical(own[2], "640"))

cat("INSPECT OK: cid", cid, "-> durable intent+outcome, actor uid:", uid,
    "(not root), root-owned 0640 system sink\n")
