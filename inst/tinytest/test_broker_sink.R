## AF_UNIX audit-broker client sink. Drives the SINGLE cross-repo fixture corpus
## (inst/tinytest/fixtures/broker-frames/, also vendored by runix-audit-broker):
## body fixtures through the strict validator, frame fixtures through the C
## transport via a hostile fake responder. Plus fail-closed-with-no-broker,
## the server-peer-not-root refusal, the anti-laundering scope downgrade, and
## live round-trips against the real broker binary when one is provided.
library(runix)

parse_resp <- getFromNamespace(".broker_parse_response", "runix")

## ---- the shared fixture corpus ------------------------------------------
fx_dir <- "fixtures/broker-frames"
if (!file.exists(file.path(fx_dir, "manifest.tsv"))) {
    fx_dir <- system.file("tinytest", "fixtures", "broker-frames",
                          package = "runix")
}
man <- read.delim(file.path(fx_dir, "manifest.tsv"), stringsAsFactors = FALSE)
read_fixture <- function(file) {
    readBin(file.path(fx_dir, file), "raw",
            n = file.info(file.path(fx_dir, file))$size)
}
expect_true(nrow(man) > 0L)

## ---- body fixtures: the strict validator (no broker needed) --------------
bodies <- man[man$layer == "body", , drop = FALSE]
expect_true(nrow(bodies) > 0L)
for (i in seq_len(nrow(bodies))) {
    row <- bodies[i, ]
    v <- parse_resp(read_fixture(row$file))
    accepted <- !identical(v$kind, "invalid")
    expect_equal(accepted, row$accept == 1L, info = paste("body", row$name))
    if (row$accept == 1L) {
        expect_equal(v$kind, row$tag, info = paste("kind", row$name))
    }
    ## the dup fixtures (top-level and nested) must be rejected at parse time:
    ## janssonr's parser refuses duplicate keys at any depth, so a dup body never
    ## reaches the shape checks -- it fails as a parse error.
    if (identical(row$tag, "dup")) {
        expect_equal(v$reason, "parse error",
                     info = paste("dup tripwire", row$name))
    }
}

## ---- capabilities: forward-extensible discovery response -----------------
## The shared golden above covers today's empty response; these pin classifier
## behaviour on the future populated shape and on malformed inputs.
## a populated response (effect_receipt + a plan schema) still classifies:
expect_equal(parse_resp(paste0(
    '{"extensions":{"effect_receipt":1},"frame_version":1,"ok":true,',
    '"plan_schemas":[1],"record_schema_version":1}'))$kind, "capabilities_ok")
## an unknown extension name is ignored, not rejected (forward-extensible):
expect_equal(parse_resp(paste0(
    '{"extensions":{"effect_receipt":1,"future_thing":2},"frame_version":1,',
    '"ok":true,"plan_schemas":[1],"record_schema_version":1}'))$kind,
    "capabilities_ok")
## malformed capabilities are rejected, never a silent accept:
expect_equal(parse_resp(paste0(  # frame_version not an integer
    '{"extensions":{},"frame_version":"1","ok":true,',
    '"plan_schemas":[],"record_schema_version":1}'))$kind, "invalid")
expect_equal(parse_resp(paste0(  # plan_schemas element not an integer
    '{"extensions":{},"frame_version":1,"ok":true,',
    '"plan_schemas":["1"],"record_schema_version":1}'))$kind, "invalid")
expect_equal(parse_resp(paste0(  # extensions is an array, not an object
    '{"extensions":[],"frame_version":1,"ok":true,',
    '"plan_schemas":[],"record_schema_version":1}'))$kind, "invalid")
expect_equal(parse_resp(paste0(  # a known extension with a non-integer version
    '{"extensions":{"effect_receipt":"1"},"frame_version":1,"ok":true,',
    '"plan_schemas":[],"record_schema_version":1}'))$kind, "invalid")
## JSON reals are not integers: the protocol requires actual JSON integers,
## matching Jansson's json_is_integer() (janssonr keeps 1.0 a double, 1 an int).
expect_equal(parse_resp(paste0(  # frame_version is a JSON real
    '{"extensions":{},"frame_version":1.0,"ok":true,',
    '"plan_schemas":[],"record_schema_version":1}'))$kind, "invalid")
expect_equal(parse_resp(paste0(  # record_schema_version is a JSON real
    '{"extensions":{},"frame_version":1,"ok":true,',
    '"plan_schemas":[],"record_schema_version":1.0}'))$kind, "invalid")
expect_equal(parse_resp(paste0(  # a plan schema is a JSON real
    '{"extensions":{},"frame_version":1,"ok":true,',
    '"plan_schemas":[1.0],"record_schema_version":1}'))$kind, "invalid")
expect_equal(parse_resp(paste0(  # effect_receipt is a JSON real
    '{"extensions":{"effect_receipt":1.0},"frame_version":1,"ok":true,',
    '"plan_schemas":[],"record_schema_version":1}'))$kind, "invalid")
## versions are 1-based: zero and negatives are rejected.
expect_equal(parse_resp(paste0(  # zero version
    '{"extensions":{},"frame_version":0,"ok":true,',
    '"plan_schemas":[],"record_schema_version":1}'))$kind, "invalid")
expect_equal(parse_resp(paste0(  # negative version
    '{"extensions":{},"frame_version":-1,"ok":true,',
    '"plan_schemas":[],"record_schema_version":1}'))$kind, "invalid")

## ---- effect-receipt shapes: receipt-bearing open, redeem, new errors -----
## The shared goldens above pin the happy shapes; these pin the classifier's
## strictness on the receipt additions (broker-effect-receipt-contract.md).
rcid <- "00001786382512165708-a061ec02cffe1b2b"
rbind <- "c7eb72753bf700824daf45442abd39c2"
rrcpt <- "1b9d6bcd1e7f4a3bd2c5e8f0a4d7c9e2"
## a receipt-bearing open_ok classifies distinctly from a plain open_ok:
expect_equal(parse_resp(sprintf(paste0(
    '{"audit_scope":"system","binding":"%s","correlation_id":"%s",',
    '"effect_receipt":"%s","ok":true,"persisted":true}'),
    rbind, rcid, rrcpt))$kind, "open_ok_effect")
## a malformed effect_receipt is rejected, never downgraded to a plain open_ok:
expect_equal(parse_resp(sprintf(paste0(
    '{"audit_scope":"system","binding":"%s","correlation_id":"%s",',
    '"effect_receipt":"nothex","ok":true,"persisted":true}'),
    rbind, rcid))$kind, "invalid")
## effect_receipt must be distinct from the binding: identical (well-formed)
## tokens are a malformed response, not a valid receipt-bearing open.
expect_equal(parse_resp(sprintf(paste0(
    '{"audit_scope":"system","binding":"%s","correlation_id":"%s",',
    '"effect_receipt":"%s","ok":true,"persisted":true}'),
    rbind, rcid, rbind))$kind, "invalid")
## redeem_ok is a correlation id only -- no binding, no audit_scope:
expect_equal(parse_resp(sprintf(
    '{"correlation_id":"%s","ok":true,"persisted":true}', rcid))$kind,
    "redeem_ok")
## a redeem_ok with a bad correlation id is rejected:
expect_equal(parse_resp('{"correlation_id":"nope","ok":true,"persisted":true}'
    )$kind, "invalid")
## a 4-key body matching no exact shape (binding without audit_scope) is invalid:
expect_equal(parse_resp(sprintf(
    '{"binding":"%s","correlation_id":"%s","ok":true,"persisted":true}',
    rbind, rcid))$kind, "invalid")
## each new receipt error code is inside the closed set:
for (code in c("receipt_invalid", "receipt_expired", "receipt_redeemed",
               "receipt_mismatch", "receipt_unauthorized",
               "receipt_actor_mismatch", "effect_without_receipt")) {
    expect_equal(parse_resp(sprintf(
        '{"error":"%s","message":"m","ok":false}', code))$kind, "error",
        info = code)
}

## ---- fail-closed with no broker (unavailable), never throws -------------
## Works on every platform: a missing socket is ST_UNAVAILABLE on Linux and
## ST_UNSUPPORTED off it -- both map to runix_broker_unavailable. A failed
## receipt claims NO audit scope.
s0 <- broker_audit_sink(socket_path = tempfile("no-broker-"), connect_ms = 200L,
                        recv_ms = 200L, send_ms = 200L)
r0 <- s0$open_intent(list(operation = "x", outcome = "intent"))
expect_false(isTRUE(r0$persisted))
expect_equal(r0$error, "runix_broker_unavailable")
expect_true(is.na(r0$binding))
expect_true(is.na(r0$audit_scope))
e0 <- s0$emit(list(operation = "x", outcome = "preview", effect_issued = FALSE),
              "preview")
expect_false(isTRUE(e0$persisted))
expect_equal(e0$error, "runix_broker_unavailable")
## a wrong emit phase is rejected LOCALLY, before any transport
expect_equal(s0$emit(list(operation = "x", outcome = "ok"), "outcome")$error,
             "runix_broker_bad_phase")
expect_equal(s0$emit(list(operation = "x"), "intent")$error,
             "runix_broker_bad_phase")
## reserved identity/framing keys are refused LOCALLY, before any transport:
## the broker owns actor/host/pid/time and mints correlation_id/binding, so a
## record that leaks one fails closed and named here rather than being stripped
## or only rejected at the wire (audit-broker-contract.md). This is the exact
## producer bug the canary found: a subsystem putting actor in domain content.
for (k in c("actor", "correlation_id", "phase", "host", "pid", "time",
            "binding", "broker", "record_type", "schema_version")) {
    rec <- list(operation = "x", outcome = "intent")
    rec[[k]] <- "z"
    expect_equal(s0$open_intent(rec)$error, "runix_broker_reserved_field",
                 info = paste("open_intent reserved:", k))
}
## emit (valid phase) and write_outcome (valid binding) reject them too, and the
## reserved check precedes the binding check.
expect_equal(s0$emit(list(operation = "x", outcome = "preview",
                          actor = "uid:0"), "preview")$error,
             "runix_broker_reserved_field")
expect_equal(s0$write_outcome(list(binding = "deadbeef"),
                              list(operation = "x", outcome = "ok",
                                   actor = "uid:0"))$error,
             "runix_broker_reserved_field")
## a clean record still passes the local check and reaches transport
## (unavailable here, since there is no broker) -- proof the gate is specific.
expect_equal(s0$open_intent(list(operation = "x", outcome = "intent"))$error,
             "runix_broker_unavailable")
## no-binding guard: refuse before any transport
expect_equal(s0$write_outcome(list(binding = NA_character_),
                              list(outcome = "ok"))$error,
             "runix_broker_no_binding")
## a non-empty binding but no broker -> unavailable (still fail-closed)
expect_equal(s0$write_outcome(list(binding = "deadbeef"),
                              list(outcome = "ok"))$error,
             "runix_broker_unavailable")
## defensive .Call validation errors on misuse (bad types / NA / negative)
expect_error(runix:::.broker_call(NA_character_, "{}"), "non-NA string")
expect_error(runix:::.broker_call(tempfile(), "{}", connect_ms = -1L),
             "non-negative")

## capability probe: a runtime, root-authenticated check, never a Boolean or
## socket-existence guess. No socket -> unavailable -> not system-durable.
expect_equal(broker_available(tempfile(fileext = ".sock"), connect_ms = 200L),
             "unavailable")
expect_true(system_durable_audit_available(root = TRUE))
expect_false(system_durable_audit_available(root = FALSE,
    socket_path = tempfile(fileext = ".sock"), connect_ms = 200L))

## ---- hostile fake responder (Linux + parallel only) ---------------------
## Every byte on the wire is a corpus frame fixture or a corpus body wrapped in
## a frame: the client must fail closed against malformed frames, semantic
## garbage in valid frames, an unprivileged (non-root) peer, and a silent
## server, and it must never launder system scope from a non-root peer.
is_linux <- identical(Sys.info()[["sysname"]], "Linux")
if (tinytest::at_home() && is_linux &&
    requireNamespace("parallel", quietly = TRUE)) {

    old_allow <- Sys.getenv("RUNIX_ALLOW_TEST_SERVER", unset = NA)
    Sys.setenv(RUNIX_ALLOW_TEST_SERVER = "1")
    on.exit({
        if (is.na(old_allow)) {
            Sys.unsetenv("RUNIX_ALLOW_TEST_SERVER")
        } else {
            Sys.setenv(RUNIX_ALLOW_TEST_SERVER = old_allow)
        }
    }, add = TRUE)

    myuid <- suppressWarnings(as.integer(system("id -u", intern = TRUE))[1])
    expect_true(is.finite(myuid))
    expected_scope <- if (identical(myuid, 0L)) "system" else "untrusted"

    frame_of <- function(body_raw) {
        n <- length(body_raw)
        c(as.raw(1L),
          as.raw(c(bitwShiftR(n, 24L), bitwAnd(bitwShiftR(n, 16L), 255L),
                   bitwAnd(bitwShiftR(n, 8L), 255L), bitwAnd(n, 255L))),
          body_raw)
    }
    ## serve `reply` bytes verbatim, run fn(sink), return fn's value
    exchange <- function(reply, fn, expected_uid = myuid, delay_ms = 0L,
                         recv_ms = 2000L) {
        sock <- tempfile("fake-broker-")
        child <- parallel::mcparallel(
            runix:::.broker_test_serve_once(sock, reply, read_first = TRUE,
                                            delay_ms = delay_ms))
        for (i in 1:200) {
            if (file.exists(sock)) break
            Sys.sleep(0.01)
        }
        s <- runix:::.broker_audit_sink(sock, connect_ms = 2000L,
                                        recv_ms = recv_ms, send_ms = 2000L,
                                        expected_peer_uid = expected_uid)
        out <- fn(s)
        parallel::mccollect(child)
        out
    }
    open1 <- function(s) s$open_intent(list(operation = "x", outcome = "intent"))
    valid_frame <- read_fixture("frame_valid_open.frame")

    ## non-vacuity + anti-laundering: a byte-perfect open_ok over a peer this
    ## sink expects succeeds, but a non-root peer NEVER earns system scope.
    ok <- exchange(valid_frame, open1)
    expect_true(isTRUE(ok$persisted))
    expect_equal(ok$audit_scope, expected_scope)
    if (!identical(myuid, 0L)) {
        expect_true(!identical(ok$audit_scope, "system"))
    }

    ## SERVER PEER NOT ROOT: the production sink (expected uid 0) refuses this
    ## same valid responder BEFORE sending the request.
    pr <- exchange(valid_frame, open1, expected_uid = 0L)
    expect_false(isTRUE(pr$persisted))
    expect_equal(pr$error, "runix_broker_untrusted_peer")
    expect_true(is.na(pr$audit_scope))

    ## every corpus FRAME fixture, through the real transport
    frames <- man[man$layer == "frame", , drop = FALSE]
    expect_true(nrow(frames) > 0L)
    for (i in seq_len(nrow(frames))) {
        row <- frames[i, ]
        res <- exchange(read_fixture(row$file), open1)
        if (row$accept == 1L) {
            ## a well-formed frame whose body is open_ok -> the record persists
            expect_true(isTRUE(res$persisted), info = paste("frame", row$name))
        } else {
            expect_equal(res$error, "runix_broker_bad_response",
                         info = paste("frame", row$name))
        }
    }

    ## semantic garbage inside a valid FRAME survives the wire and is refused:
    ## wrap a shape-valid-but-wrong-scope body in a real frame.
    sem <- exchange(frame_of(read_fixture("scope_not_system.json")), open1)
    expect_equal(sem$error, "runix_broker_bad_response")

    ## deadline behaviour: a server that reads then stays silent past the recv
    ## deadline is a typed timeout, within the bound (time the client call only)
    took <- NA_real_
    silent <- exchange(valid_frame, function(s) {
        t0 <- Sys.time()
        out <- open1(s)
        took <<- as.numeric(difftime(Sys.time(), t0, units = "secs"))
        out
    }, delay_ms = 2000L, recv_ms = 300L)
    expect_equal(silent$error, "runix_broker_timeout")
    expect_true(is.finite(took) && took < 1.5)
}

## ---- live broker (gated) -----------------------------------------------
broker_bin <- Sys.getenv("RUNIX_TEST_BROKER_BIN")
if (tinytest::at_home() && is_linux && nzchar(broker_bin) &&
    file.exists(broker_bin)) {
    dir <- tempfile("rab-live-")
    dir.create(dir)
    sock <- file.path(dir, "sock")
    sink <- file.path(dir, "audit.jsonl")
    myuid <- suppressWarnings(as.integer(system("id -u", intern = TRUE))[1])
    ## the test broker runs as this (typically non-root) uid, so its sink is
    ## scoped "untrusted"; a root broker (root-run CI, the VM gate) is "system".
    expected_scope <- if (identical(myuid, 0L)) "system" else "untrusted"

    launch <- function() {
        cmd <- sprintf("%s --listen %s --sink %s >/dev/null 2>&1 & echo $!",
                       shQuote(broker_bin), shQuote(sock), shQuote(sink))
        pid <- suppressWarnings(system(cmd, intern = TRUE))
        pid <- pid[grepl("^[0-9]+$", pid)][1]
        for (i in 1:200) {
            if (file.exists(sock)) break
            Sys.sleep(0.02)
        }
        pid
    }
    kill_broker <- function(pid) {
        if (!is.na(pid)) {
            system(paste("kill", pid, "2>/dev/null"))
        }
    }
    pid <- launch()
    on.exit({
        kill_broker(pid)
        unlink(dir, recursive = TRUE, force = TRUE)
    }, add = TRUE)
    expect_true(file.exists(sock))

    ## the test broker runs unprivileged, so the internal seam pins ITS uid; the
    ## public root-only constructor is exercised by the peer test above + the VM
    ## gate. A non-root peer is scoped "untrusted", never "system".
    s <- runix:::.broker_audit_sink(sock, connect_ms = 2000L, recv_ms = 5000L,
                                    send_ms = 5000L, expected_peer_uid = myuid)

    r <- s$open_intent(list(operation = "svc.restart", outcome = "intent"))
    expect_true(isTRUE(r$persisted))
    expect_equal(r$audit_scope, expected_scope)
    expect_true(grepl("^[0-9a-f]{32}$", r$binding))
    expect_true(grepl("^[0-9]{20}-[0-9a-f]{16}$", r$correlation_id))
    st <- s$write_outcome(r, list(operation = "svc.restart", outcome = "ok",
                                  effect_issued = TRUE))
    expect_true(isTRUE(st$persisted))

    e <- s$emit(list(operation = "svc.restart", outcome = "preview",
                     effect_issued = FALSE), "preview")
    expect_true(isTRUE(e$persisted))
    expect_true(is.null(e$binding))
    expect_true(grepl("^[0-9]{20}-[0-9a-f]{16}$", e$correlation_id))

    ## broker error: an outcome for a bogus binding is unknown_intent,
    ## fail-closed with the broker's own code (never the binding)
    bad <- s$write_outcome(list(binding = "deadbeefdeadbeefdeadbeefdeadbeef"),
                           list(operation = "svc.restart", outcome = "ok",
                                effect_issued = TRUE))
    expect_false(isTRUE(bad$persisted))
    expect_equal(bad$error, "unknown_intent")

    ## restart between phases: the intent is durable; the same process closes it
    ## after the broker restarts (full-identity match survives).
    r2 <- s$open_intent(list(operation = "svc.restart", outcome = "intent"))
    expect_true(isTRUE(r2$persisted))
    kill_broker(pid)
    Sys.sleep(0.2)
    pid <- launch()
    expect_true(file.exists(sock))
    st2 <- s$write_outcome(r2, list(operation = "svc.restart", outcome = "ok",
                                    effect_issued = TRUE))
    expect_true(isTRUE(st2$persisted))

    ## same-process full identity: a DIFFERENT process (a fork) cannot close
    ## another process's intent -- the broker sees a different peer pid.
    r3 <- s$open_intent(list(operation = "svc.restart", outcome = "intent"))
    expect_true(isTRUE(r3$persisted))
    if (requireNamespace("parallel", quietly = TRUE)) {
        child <- parallel::mcparallel(
            runix:::.broker_audit_sink(sock, 2000L, 5000L, 5000L,
                                       expected_peer_uid = myuid)$write_outcome(
                r3, list(operation = "svc.restart", outcome = "ok",
                         effect_issued = TRUE)))
        cres <- parallel::mccollect(child)[[1]]
        expect_false(isTRUE(cres$persisted))
        expect_equal(cres$error, "actor_mismatch")
        expect_true(isTRUE(s$write_outcome(r3,
            list(operation = "svc.restart", outcome = "ok",
                 effect_issued = TRUE))$persisted))
    }

    ## capability probe against the (non-root) test broker: reachable, but NOT
    ## trusted as root, so it does not make system-durable audit available -- and
    ## the probe is side-effect-free (writes no record).
    before_n <- length(readLines(sink, warn = FALSE))
    expect_equal(broker_available(sock, connect_ms = 1000L), "untrusted")
    expect_false(system_durable_audit_available(root = FALSE, socket_path = sock,
                                                connect_ms = 1000L))
    expect_equal(length(readLines(sink, warn = FALSE)), before_n)

    ## the sink reconstructs clean and every recorded actor is this uid
    kill_broker(pid)
    pid <- NA_integer_
    Sys.sleep(0.1)
    lines <- readLines(sink, warn = FALSE)
    expect_true(length(lines) > 0L)
    all_mine <- TRUE
    for (ln in lines) {
        rec <- tryCatch(janssonr::from_json(ln), error = function(e) NULL)
        if (is.null(rec)) next
        if (identical(rec$record_type, "audit")) {
            if (!identical(as.integer(rec$broker$peer$uid), myuid)) {
                all_mine <- FALSE
            }
        }
    }
    expect_true(all_mine)
}
