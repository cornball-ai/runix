## AF_UNIX audit-broker client sink: strict response validation (with the
## yyjsonr duplicate-key tripwire), fail-closed behaviour with no broker, and
## live round-trips against the real broker binary when one is provided.
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
## ST_UNSUPPORTED off it -- both map to runix_broker_unavailable.
s0 <- broker_audit_sink(socket_path = tempfile("no-broker-"), connect_ms = 200L,
                        recv_ms = 200L, send_ms = 200L)
r0 <- s0$open_intent(list(operation = "x", outcome = "intent"))
expect_false(isTRUE(r0$persisted))
expect_equal(r0$error, "runix_broker_unavailable")
expect_true(is.na(r0$binding))
expect_equal(r0$audit_scope, "system")
e0 <- s0$emit(list(operation = "x", outcome = "preview", effect_issued = FALSE),
              "preview")
expect_false(isTRUE(e0$persisted))
expect_equal(e0$error, "runix_broker_unavailable")
## no-binding guard: refuse before any transport
nb <- s0$write_outcome(list(binding = NA_character_), list(outcome = "ok"))
expect_equal(nb$error, "runix_broker_no_binding")
## a non-empty binding but no broker -> unavailable (still fail-closed)
wo <- s0$write_outcome(list(binding = "deadbeef"), list(outcome = "ok"))
expect_equal(wo$error, "runix_broker_unavailable")

## ---- live broker (gated) -----------------------------------------------
broker_bin <- Sys.getenv("RUNIX_TEST_BROKER_BIN")
if (tinytest::at_home() && nzchar(broker_bin) && file.exists(broker_bin)) {
    dir <- tempfile("rab-live-")
    dir.create(dir)
    sock <- file.path(dir, "sock")
    sink <- file.path(dir, "audit.jsonl")

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

    s <- broker_audit_sink(socket_path = sock)

    ## happy path: open_intent -> write_outcome, system-durable
    r <- s$open_intent(list(operation = "svc.restart", outcome = "intent"))
    expect_true(isTRUE(r$persisted))
    expect_equal(r$audit_scope, "system")
    expect_true(is.character(r$binding) && nzchar(r$binding))
    expect_true(is.character(r$correlation_id) && nzchar(r$correlation_id))
    st <- s$write_outcome(r, list(operation = "svc.restart", outcome = "ok",
                                  effect_issued = TRUE))
    expect_true(isTRUE(st$persisted))

    ## emit: a single non-effect record, minted id, no binding
    e <- s$emit(list(operation = "svc.restart", outcome = "preview",
                     effect_issued = FALSE), "preview")
    expect_true(isTRUE(e$persisted))
    expect_true(is.null(e$binding))
    expect_true(nzchar(e$correlation_id))

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
    if (requireNamespace("parallel", quietly = TRUE) &&
        .Platform$OS.type == "unix") {
        child <- parallel::mcparallel(
            broker_audit_sink(socket_path = sock)$write_outcome(
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
    myuid <- suppressWarnings(as.integer(system("id -u", intern = TRUE))[1])
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
