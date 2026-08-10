## AF_UNIX audit-broker client sink: strict response validation (with the
## yyjsonr duplicate-key tripwire), fail-closed behaviour with no broker, a
## hostile fake responder (malformed frames, semantic garbage, untrusted peer,
## deadlines), and live round-trips against the real broker binary when one is
## provided.
library(runix)

parse_resp <- getFromNamespace(".broker_parse_response", "runix")

## ---- response validator corpus (no broker needed) -----------------------
fx <- "fixtures/broker_responses.R"
if (!file.exists(fx)) {
    fx <- system.file("tinytest", "fixtures", "broker_responses.R",
                      package = "runix")
}
broker_response_fixtures <- NULL
source(fx, local = TRUE)
expect_true(length(broker_response_fixtures) > 0L)
for (f in broker_response_fixtures) {
    v <- parse_resp(f$body)
    accepted <- !identical(v$kind, "invalid")
    expect_equal(accepted, isTRUE(f$accept), info = paste("fixture", f$name))
    if (isTRUE(f$accept)) {
        expect_equal(v$kind, f$kind, info = paste("kind", f$name))
    }
    ## the dup-key fixtures must be rejected specifically via the recursive
    ## dup path -- the yyjsonr behavioural tripwire
    if (isTRUE(f$dup)) {
        expect_equal(v$reason, "duplicate or empty key",
                     info = paste("dup tripwire", f$name))
    }
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
ep <- s0$emit(list(operation = "x", outcome = "ok"), "outcome")
expect_false(isTRUE(ep$persisted))
expect_equal(ep$error, "runix_broker_bad_phase")
ep2 <- s0$emit(list(operation = "x", outcome = "intent"), "intent")
expect_equal(ep2$error, "runix_broker_bad_phase")
## no-binding guard: refuse before any transport
nb <- s0$write_outcome(list(binding = NA_character_), list(outcome = "ok"))
expect_equal(nb$error, "runix_broker_no_binding")
## a non-empty binding but no broker -> unavailable (still fail-closed)
wo <- s0$write_outcome(list(binding = "deadbeef"), list(outcome = "ok"))
expect_equal(wo$error, "runix_broker_unavailable")
## defensive .Call validation errors on misuse (bad types / NA / negative)
expect_error(runix:::.broker_call(NA_character_, "{}"), "non-NA string")
expect_error(runix:::.broker_call(tempfile(), "{}", connect_ms = -1L),
             "non-negative")

## ---- hostile fake responder (Linux + parallel only) ---------------------
## Every byte on the wire is controlled by the test: the client must fail
## closed against malformed frames, semantic garbage in valid frames, an
## unprivileged (non-root) peer, a silent server, and an immediate close.
is_linux <- identical(Sys.info()[["sysname"]], "Linux")
if (tinytest::at_home() && is_linux &&
    requireNamespace("parallel", quietly = TRUE)) {

    ## the test responder is inert unless explicitly enabled
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
    ## a non-root peer never earns system scope (this uid pins itself via the
    ## seam); root-run CI would earn "system".
    expected_scope <- if (identical(myuid, 0L)) "system" else "untrusted"

    be32 <- function(n) {
        as.raw(c(bitwAnd(bitwShiftR(n, 24L), 255L),
                 bitwAnd(bitwShiftR(n, 16L), 255L),
                 bitwAnd(bitwShiftR(n, 8L), 255L),
                 bitwAnd(n, 255L)))
    }
    frame <- function(body, version = 1L) {
        b <- charToRaw(body)
        c(as.raw(version), be32(length(b)), b)
    }
    ## Run one fake-server exchange: serve `reply` bytes, drive `fn(sink)`,
    ## return fn's value. The sink trusts THIS uid (the internal test seam)
    ## unless `expected_uid` says otherwise.
    exchange <- function(reply, fn, expected_uid = myuid, read_first = TRUE,
                         delay_ms = 0L, recv_ms = 2000L) {
        sock <- tempfile("fake-broker-")
        child <- parallel::mcparallel(
            runix:::.broker_test_serve_once(sock, reply,
                                            read_first = read_first,
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
    VALID_OPEN <- paste0(
        '{"audit_scope":"system",',
        '"binding":"c7eb72753bf700824daf45442abd39c2",',
        '"correlation_id":"00001786382512165708-a061ec02cffe1b2b",',
        '"ok":true,"persisted":true}')

    ## non-vacuity: a well-formed reply from a peer whose uid this sink expects
    ## succeeds, so every refusal below is the guard, not a broken harness. And
    ## it proves the anti-laundering downgrade: even a byte-perfect open_ok
    ## claiming "system" yields an "untrusted" receipt when the peer is not root.
    ok <- exchange(frame(VALID_OPEN), open1)
    expect_true(isTRUE(ok$persisted))
    expect_equal(ok$audit_scope, expected_scope)
    if (!identical(myuid, 0L)) {
        expect_true(!identical(ok$audit_scope, "system"))
    }

    ## SERVER PEER NOT ROOT: the production sink (expected uid 0) refuses this
    ## same valid-looking responder BEFORE sending the request -- a malicious
    ## local socket cannot fake a persisted system record.
    pr <- exchange(frame(VALID_OPEN), open1, expected_uid = 0L)
    expect_false(isTRUE(pr$persisted))
    expect_equal(pr$error, "runix_broker_untrusted_peer")
    expect_true(is.na(pr$audit_scope))

    ## malformed frames
    bad_version <- exchange(frame(VALID_OPEN, version = 2L), open1)
    expect_equal(bad_version$error, "runix_broker_bad_response")
    oversize <- exchange(c(as.raw(1), be32(200000L)), open1)
    expect_equal(oversize$error, "runix_broker_bad_response")
    truncated <- exchange(c(as.raw(1), be32(100L), charToRaw("short")), open1)
    expect_equal(truncated$error, "runix_broker_bad_response")
    closed_no_reply <- exchange(raw(0), open1)
    expect_equal(closed_no_reply$error, "runix_broker_io")

    ## semantic garbage inside a valid frame
    scope_caller <- exchange(frame(sub("system", "caller", VALID_OPEN)), open1)
    expect_equal(scope_caller$error, "runix_broker_bad_response")
    nested_dup <- exchange(
        frame('{"ok":true,"persisted":true,"x":{"a":1,"a":2}}'), open1)
    expect_equal(nested_dup$error, "runix_broker_bad_response")
    rogue_code <- exchange(
        frame('{"error":"made_up_code","message":"x","ok":false}'), open1)
    expect_equal(rogue_code$error, "runix_broker_bad_response")

    ## deadline behaviour: a server that accepts, reads, and stays silent past
    ## the recv deadline is a typed timeout, within the bound. Timed around the
    ## CLIENT call only (the harness afterwards waits out the server child).
    took <- NA_real_
    silent <- exchange(frame(VALID_OPEN), function(s) {
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
    ## scoped "untrusted"; a root broker (root-run CI, or the VM gate) is "system".
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

    ## the test broker runs unprivileged, so the internal seam pins ITS uid;
    ## the public constructor (root-only) is exercised by the fake-responder
    ## peer test above and the VM gate.
    s <- runix:::.broker_audit_sink(sock, connect_ms = 2000L, recv_ms = 5000L,
                                    send_ms = 5000L, expected_peer_uid = myuid)

    ## happy path: open_intent -> write_outcome, system-durable
    r <- s$open_intent(list(operation = "svc.restart", outcome = "intent"))
    expect_true(isTRUE(r$persisted))
    expect_equal(r$audit_scope, expected_scope)
    expect_true(grepl("^[0-9a-f]{32}$", r$binding))
    expect_true(grepl("^[0-9]{20}-[0-9a-f]{16}$", r$correlation_id))
    st <- s$write_outcome(r, list(operation = "svc.restart", outcome = "ok",
                                  effect_issued = TRUE))
    expect_true(isTRUE(st$persisted))

    ## emit: a single non-effect record, minted id, no binding
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
        ## and the true opener still can close it
        expect_true(isTRUE(s$write_outcome(r3,
            list(operation = "svc.restart", outcome = "ok",
                 effect_issued = TRUE))$persisted))
    }

    ## the sink reconstructs clean and every recorded actor is this uid
    kill_broker(pid)
    pid <- NA_integer_
    Sys.sleep(0.1)
    lines <- readLines(sink, warn = FALSE)
    expect_true(length(lines) > 0L)
    all_mine <- TRUE
    for (ln in lines) {
        rec <- tryCatch(yyjsonr::read_json_str(ln), error = function(e) NULL)
        if (is.null(rec)) next
        if (identical(rec$record_type, "audit")) {
            if (!identical(as.integer(rec$broker$peer$uid), myuid)) {
                all_mine <- FALSE
            }
        }
    }
    expect_true(all_mine)
}
