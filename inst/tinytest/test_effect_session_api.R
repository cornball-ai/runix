# The exported three-call session surface (R/effect_session_api.R): the opaque
# handle object, argument-shape checks, and the typed-condition mapping on top
# of the native C shims. The full open/commit/write_outcome flow needs the
# compile-time -DRUNIX_TESTING seam (a fake entrypoint + a non-root peer), so it
# runs there and skips otherwise; the wrapper-only checks run everywhere.

is_linux <- identical(Sys.info()[["sysname"]], "Linux")
plan_hash <- strrep("c", 64)

## ---- handle-object validation (no server) --------------------------------
## commit/write_outcome refuse anything that is not a session handle object
expect_error(runix:::effect_session_commit("not a session"),
             "not a runix effect session")
expect_error(runix:::effect_session_commit(list(handle = 1L)),
             "not a runix effect session")
expect_error(runix:::effect_session_write_outcome(42L, list(a = 1)),
             "not a runix effect session")

## ---- open failure maps to a typed, secret-free condition (no server) -----
if (is_linux) {
    ## a nonexistent socket -> the transport "unavailable" -> runix_broker_unavailable
    e <- tryCatch(
        effect_session_open(tempfile(fileext = ".sock"), "apt.install", "nginx",
                            1L, plan_hash, connect_ms = 200L),
        condition = function(c) c)
    expect_true(inherits(e, "runix_broker_unavailable"))
    expect_true(inherits(e, "runix_error"))
    expect_equal(e$status, "unavailable")
    expect_equal(e$operation, "apt.install")

    ## a malformed plan hash -> the C bad_request -> runix_broker_bad_request,
    ## detail names the offending field
    e2 <- tryCatch(
        effect_session_open(tempfile(fileext = ".sock"), "apt.install", "nginx",
                            1L, "tooshort", connect_ms = 200L),
        condition = function(c) c)
    expect_true(inherits(e2, "runix_broker_bad_request"))
    expect_equal(e2$detail, "plan_hash")

    ## an unknown apt verb is a hard error from the C closed enum
    expect_error(
        effect_session_open(tempfile(fileext = ".sock"), "apt.frobnicate",
                            "nginx", 1L, plan_hash),
        "unknown apt operation")

    ## fractional numeric arguments are rejected before any coercion or call --
    ## never silently truncated (plan_schema = 1.5 must not become 1)
    expect_error(
        effect_session_open(tempfile(fileext = ".sock"), "apt.install", "nginx",
                            1.5, plan_hash),
        "integer value")
    expect_error(
        effect_session_open(tempfile(fileext = ".sock"), "apt.install", "nginx",
                            1L, plan_hash, connect_ms = 200.5),
        "integer value")
}

## ---- full flow through the exported API (compile-time seam only) ----------
if (is_linux && runix:::.effect_session_testing() && tinytest::at_home() &&
    requireNamespace("parallel", quietly = TRUE)) {

    old_allow <- Sys.getenv("RUNIX_ALLOW_TEST_SERVER", unset = NA)
    Sys.setenv(RUNIX_ALLOW_TEST_SERVER = "1")
    myuid <- suppressWarnings(as.integer(system("id -u", intern = TRUE))[1])
    old_peer <- Sys.getenv("RUNIX_TEST_PEER_UID", unset = NA)
    Sys.setenv(RUNIX_TEST_PEER_UID = myuid)
    on.exit({
        if (is.na(old_allow)) {
            Sys.unsetenv("RUNIX_ALLOW_TEST_SERVER")
        } else {
            Sys.setenv(RUNIX_ALLOW_TEST_SERVER = old_allow)
        }
        if (is.na(old_peer)) {
            Sys.unsetenv("RUNIX_TEST_PEER_UID")
        } else {
            Sys.setenv(RUNIX_TEST_PEER_UID = old_peer)
        }
        Sys.unsetenv(c("RUNIX_TEST_ENTRYPOINT", "RUNIX_TEST_RESULT"))
    }, add = TRUE)

    frame_of <- function(body_raw) {
        n <- length(body_raw)
        c(as.raw(1L),
          as.raw(c(bitwShiftR(n, 24L), bitwAnd(bitwShiftR(n, 16L), 255L),
                   bitwAnd(bitwShiftR(n, 8L), 255L), bitwAnd(n, 255L))),
          body_raw)
    }
    frame_json <- function(s) frame_of(as.raw(utf8ToInt(s)))

    cid <- paste0(strrep("0", 20), "-", "0123456789abcdef")
    receipt <- strrep("b", 32)
    binding <- strrep("a", 32)
    open_ok_effect <- runix:::encode_json_line(list(
        ok = TRUE, persisted = TRUE, audit_scope = "system",
        correlation_id = cid, binding = binding, effect_receipt = receipt))
    outcome_ok <- runix:::encode_json_line(list(ok = TRUE, persisted = TRUE))

    ## fake entrypoint: emit a chosen result on stdout, exit 0
    fake <- tempfile("fake-entry-", fileext = ".sh")
    writeLines(c("#!/bin/sh", "cat >/dev/null",
                 "[ -n \"$RUNIX_TEST_RESULT\" ] && printf '%s' \"$RUNIX_TEST_RESULT\"",
                 "exit 0"), fake)
    Sys.chmod(fake, "0755")
    result_ok <- runix:::encode_json_line(list(
        status = "ok", effect_issued = TRUE, correlation_id = cid, detail = ""))
    Sys.setenv(RUNIX_TEST_ENTRYPOINT = fake, RUNIX_TEST_RESULT = result_ok)

    sock <- tempfile("fake-api-")
    broker <- parallel::mcparallel(runix:::.broker_test_serve_seq(sock, list(
        frame_json(open_ok_effect), # conn 1: open
        frame_json(outcome_ok)      # conn 2: write_outcome
    ), read_first = TRUE))

    open_api <- function() {
        r <- NULL
        for (attempt in 1:600) {
            if (file.exists(sock)) {
                r <- tryCatch(
                    effect_session_open(sock, "apt.install", "nginx", 1L,
                                        plan_hash),
                    runix_broker_unavailable = function(c) c)
                if (!inherits(r, "condition")) break
            }
            Sys.sleep(0.02)
        }
        r
    }

    ## open returns an opaque, classed handle object -- no secrets in it
    h <- open_api()
    expect_true(inherits(h, "runix_effect_session"))
    expect_equal(h$correlation_id, cid)
    expect_equal(typeof(h$handle), "externalptr")
    ser <- serialize(h, NULL)
    expect_equal(length(grepRaw(charToRaw(receipt), ser, fixed = TRUE)), 0L)
    expect_equal(length(grepRaw(charToRaw(binding), ser, fixed = TRUE)), 0L)
    ## the print method shows state + cid, never a secret
    out <- capture.output(print(h))
    expect_true(any(grepl("opened", out)))
    expect_true(any(grepl(cid, out, fixed = TRUE)))

    ## fractional commit arguments are rejected before the receipt is spent:
    ## the session stays open, the receipt intact
    expect_error(effect_session_commit(h, lock_timeout = 1.5), "integer value")
    expect_error(effect_session_commit(h, deadline_ms = 1.5), "integer value")
    expect_equal(runix:::.effect_session_state(h$handle)$state, "opened")

    ## commit returns a classed raw result (runix does not map the status)
    cr <- effect_session_commit(h, packages = "nginx", lock_timeout = 5L,
                                deadline_ms = 5000L)
    expect_true(inherits(cr, "runix_commit_result"))
    expect_equal(cr$session_status, "ok")
    expect_equal(cr$status, "ok")
    expect_true(isTRUE(cr$effect_issued))
    expect_equal(cr$correlation_id, cid)

    ## write_outcome validates the record shape before touching the binding
    expect_error(effect_session_write_outcome(h, "not a list"),
                 "named list")
    expect_error(effect_session_write_outcome(h, list(1, 2)),
                 "named list")

    ## a well-formed outcome closes the session -> a classed status result
    wr <- effect_session_write_outcome(h, list(outcome = "ok",
                                               effect_issued = TRUE))
    expect_true(inherits(wr, "runix_outcome_result"))
    expect_equal(wr$status, "ok")

    parallel::mccollect(broker)
}
