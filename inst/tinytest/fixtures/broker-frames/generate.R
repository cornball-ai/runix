## Generator for the SINGLE cross-repo broker-response fixture corpus
## (audit-broker-contract.md). Deterministic: run it, commit its output. Both
## sides consume the same bytes -- the runix adapter (this package's
## test_broker_sink.R) and the broker daemon (runix-audit-broker, which vendors
## a copy and checks its response builder + frame reader against it).
##
## Two layers, one manifest:
##   * layer "body"  -- a response body (JSON). The adapter's validator must
##     accept/reject it; the broker's response builder must emit the "accept"
##     goldens byte-for-byte.
##   * layer "frame" -- raw wire bytes [version][uint32-be length][body]. The
##     adapter's C transport (via a fake server) and the broker's frame reader
##     must accept/reject per the fixture's category.
##
## Run from the package root:  Rscript inst/tinytest/fixtures/broker-frames/generate.R
out_dir <- file.path("inst", "tinytest", "fixtures", "broker-frames")
if (!dir.exists(out_dir)) {
    stop("run from the package root; missing ", out_dir)
}

## documented-format goldens (match src/unix_socket.c and the broker)
CID <- "00001786382512165708-a061ec02cffe1b2b"
BINDING <- "c7eb72753bf700824daf45442abd39c2"
OPEN_OK <- sprintf(paste0('{"audit_scope":"system","binding":"%s",',
                          '"correlation_id":"%s","ok":true,"persisted":true}'),
                   BINDING, CID)
OUTCOME_OK <- '{"ok":true,"persisted":true}'
EMIT_OK <- sprintf(paste0('{"audit_scope":"system","correlation_id":"%s",',
                          '"ok":true,"persisted":true}'), CID)
ERROR <- '{"error":"schema_invalid","message":"nope","ok":false}'

## body fixtures: name, accept, tag (kind for accepts; reject category else),
## body bytes
bodies <- list(
    list("open_ok", TRUE, "open_ok", OPEN_OK),
    list("outcome_ok", TRUE, "outcome_ok", OUTCOME_OK),
    list("emit_ok", TRUE, "emit_ok", EMIT_OK),
    list("error", TRUE, "error", ERROR),
    list("dup_toplevel", FALSE, "dup", '{"ok":true,"ok":true,"persisted":true}'),
    list("dup_nested", FALSE, "dup",
         '{"ok":true,"persisted":true,"x":{"a":1,"a":2}}'),
    list("scope_not_system", FALSE, "semantic",
         sub("system", "caller", OPEN_OK, fixed = TRUE)),
    list("cid_bad_format", FALSE, "semantic",
         sub(CID, "not-a-real-id", OPEN_OK, fixed = TRUE)),
    list("binding_bad_format", FALSE, "semantic",
         sub(BINDING, "XYZ", OPEN_OK, fixed = TRUE)),
    list("error_code_unknown", FALSE, "semantic",
         '{"error":"made_up_code","message":"nope","ok":false}'),
    list("extra_key", FALSE, "schema", '{"ok":true,"persisted":true,"extra":1}'),
    list("missing_persisted", FALSE, "schema", '{"ok":true}'),
    list("ok_wrong_type", FALSE, "schema", '{"ok":"true","persisted":true}'),
    list("persisted_wrong_type", FALSE, "schema",
         '{"ok":true,"persisted":"true"}'),
    list("persisted_false_on_success", FALSE, "schema",
         '{"ok":true,"persisted":false}'),
    list("error_extra", FALSE, "schema",
         '{"error":"internal","message":"y","ok":false,"z":1}'),
    list("error_missing_message", FALSE, "schema",
         '{"error":"internal","ok":false}'),
    list("error_wrong_type", FALSE, "schema",
         '{"error":123,"message":"y","ok":false}'),
    list("trailing_content", FALSE, "notjson",
         '{"ok":true,"persisted":true} trailing'),
    list("not_object_array", FALSE, "notjson", "[1,2,3]"),
    list("scalar", FALSE, "notjson", '"scalar"'),
    list("truncated_json", FALSE, "notjson", '{"ok":true,"persisted":true'),
    list("empty_object", FALSE, "notjson", "{}"))

## raw frame [version][uint32 be length][body]
be32 <- function(n) {
    as.raw(c(bitwAnd(bitwShiftR(n, 24L), 255L),
             bitwAnd(bitwShiftR(n, 16L), 255L),
             bitwAnd(bitwShiftR(n, 8L), 255L), bitwAnd(n, 255L)))
}
frame <- function(body, version = 1L) {
    b <- charToRaw(body)
    c(as.raw(version), be32(length(b)), b)
}

## frame fixtures: name, accept (a well-formed frame), category, raw bytes
frames <- list(
    list("frame_valid_open", TRUE, "valid", frame(OPEN_OK)),
    list("frame_bad_version", FALSE, "bad_version", frame(OPEN_OK, version = 2L)),
    ## length prefix claims 128 KiB (> 64 KiB cap), no body
    list("frame_oversize", FALSE, "oversize", c(as.raw(1L), be32(131072L))),
    ## header says 100 bytes, only 5 follow
    list("frame_truncated", FALSE, "truncated",
         c(as.raw(1L), be32(100L), charToRaw("short"))))

rows <- list()
for (b in bodies) {
    f <- paste0(b[[1]], ".json")
    writeBin(charToRaw(b[[4]]), file.path(out_dir, f))
    rows[[length(rows) + 1L]] <- c(b[[1]], "body",
                                   if (b[[2]]) "1" else "0", b[[3]], f)
}
for (fr in frames) {
    f <- paste0(fr[[1]], ".frame")
    writeBin(fr[[4]], file.path(out_dir, f))
    rows[[length(rows) + 1L]] <- c(fr[[1]], "frame",
                                   if (fr[[2]]) "1" else "0", fr[[3]], f)
}

man <- file.path(out_dir, "manifest.tsv")
con <- file(man, open = "wb") # LF newlines on every platform
writeLines(c("name\tlayer\taccept\ttag\tfile",
             vapply(rows, function(r) paste(r, collapse = "\t"), character(1))),
           con, sep = "\n")
close(con)
cat("wrote", length(bodies), "body +", length(frames),
    "frame fixtures and manifest.tsv to", out_dir, "\n")
