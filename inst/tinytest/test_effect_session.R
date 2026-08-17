# Native effect session (src/effect_session.c): open mints a receipt + binding
# held in wipeable C heap and returns only an opaque handle, the correlation id,
# and a status. Fixture-free -- every byte the client reads is a frame this test
# builds and a fake broker serves verbatim, so open/write_outcome/state are
# exercised without root, dpkg, or a real broker.

is_linux <- identical(Sys.info()[["sysname"]], "Linux")

## Off Linux the session is unsupported and never touches a socket.
if (!is_linux) {
    r <- runix:::.effect_session_open(tempfile(), "apt.install", "nginx", 1L,
                                      strrep("a", 64))
    expect_equal(r$status, "unsupported")
    expect_null(r$handle)
}

if (is_linux) {
    ## ---- input validation, before any socket (no server needed) -----------
    ## an unknown apt verb is a hard error (the C-owned closed enum)
    expect_error(runix:::.effect_session_open(tempfile(), "apt.frobnicate",
                                              "nginx", 1L, strrep("a", 64)),
                 "unknown apt operation")
    ## a malformed plan hash is a typed bad_request naming the field, not a
    ## connection attempt
    bad_hash <- runix:::.effect_session_open(tempfile(), "apt.install", "nginx",
                                             1L, "tooshort")
    expect_equal(bad_hash$status, "bad_request")
    expect_equal(bad_hash$detail, "plan_hash")
    expect_null(bad_hash$handle)
    ## a non-positive plan schema, an empty resource: bad_request
    expect_equal(runix:::.effect_session_open(tempfile(), "apt.install", "nginx",
                                              0L, strrep("a", 64))$status,
                 "bad_request")
    expect_equal(runix:::.effect_session_open(tempfile(), "apt.install", "",
                                              1L, strrep("a", 64))$detail,
                 "resource")
    ## a nonexistent socket is the ordinary transport "unavailable"
    expect_equal(runix:::.effect_session_open(tempfile(fileext = ".sock"),
                                              "apt.install", "nginx", 1L,
                                              strrep("a", 64),
                                              connect_ms = 200L)$status,
                 "unavailable")

    ## ---- handle misuse (no server needed) ---------------------------------
    expect_error(runix:::.effect_session_state("not a handle"),
                 "not a runix effect session handle")
    expect_error(runix:::.effect_session_state(1L),
                 "not a runix effect session handle")
}

## ---- fake broker: open / write_outcome / state (Linux + parallel) --------
if (is_linux && tinytest::at_home() &&
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
    plan_hash <- strrep("c", 64)
    open_ok_effect <- runix:::encode_json_line(list(
        ok = TRUE, persisted = TRUE, audit_scope = "system",
        correlation_id = cid, binding = binding, effect_receipt = receipt))
    outcome_ok <- runix:::encode_json_line(list(ok = TRUE, persisted = TRUE))

    ## ONE long-lived broker answers EVERY connection this test makes, in order,
    ## modelling a real broker (one path, many requests). This deliberately
    ## avoids forking a fresh server per exchange: under the test harness,
    ## mcparallel fork latency degrades after several forks and a late-binding
    ## server misses its client. The reply order below is the connection order.
    err_schema <- runix:::encode_json_line(list(
        ok = FALSE, error = "schema_invalid", message = "bad record"))
    err_madeup <- runix:::encode_json_line(list(
        ok = FALSE, error = "totally_made_up", message = "x"))
    no_receipt <- runix:::encode_json_line(list(
        ok = TRUE, persisted = TRUE, audit_scope = "system",
        correlation_id = cid, binding = binding))
    same_tokens <- runix:::encode_json_line(list(
        ok = TRUE, persisted = TRUE, audit_scope = "system",
        correlation_id = cid, binding = binding, effect_receipt = binding))
    wrong_scope <- runix:::encode_json_line(list(
        ok = TRUE, persisted = TRUE, audit_scope = "process",
        correlation_id = cid, binding = binding, effect_receipt = receipt))

    sock <- tempfile("fake-es-")
    replies <- list(
        frame_json(open_ok_effect), # conn 1: open -> success (res)
        frame_json(err_schema),     # conn 2: open -> broker_error
        frame_json(err_madeup),     # conn 3: open -> bad_response (bad code)
        frame_json(no_receipt),     # conn 4: open -> bad_response (5 keys)
        frame_json(same_tokens),    # conn 5: open -> bad_response (equal tokens)
        frame_json(wrong_scope),    # conn 6: open -> bad_response (scope)
        frame_json(outcome_ok))     # conn 7: write_outcome(res) -> ok
    broker <- parallel::mcparallel(
        runix:::.broker_test_serve_seq(sock, replies, read_first = TRUE))

    ## The child's start + bind() can lag under the harness, and its bind()
    ## creates the socket file before listen() runs, so a connect that races
    ## ahead gets ENOENT/ECONNREFUSED -> a spurious "unavailable". Wait for the
    ## file, then keep retrying the connect (the server parks on accept) until
    ## the scripted reply lands. Once bound the socket persists for every later
    ## connection, so only the first pays this wait.
    open_conn <- function() {
        r <- list(status = "unavailable")
        for (attempt in 1:600) {
            if (file.exists(sock)) {
                r <- runix:::.effect_session_open(sock, "apt.install", "nginx",
                    1L, plan_hash, expected_uid = myuid)
                if (!identical(r$status, "unavailable")) break
            }
            Sys.sleep(0.02)
        }
        r
    }
    write_conn <- function(handle, record) {
        w <- list(status = "unavailable")
        for (attempt in 1:600) {
            w <- runix:::.effect_session_write_outcome(handle, record)
            if (!identical(w$status, "unavailable")) break
            Sys.sleep(0.02)
        }
        w
    }

    ## --- conn 1: a byte-perfect open_ok_effect: handle + cid, no secret -----
    res <- open_conn()
    expect_equal(res$status, "ok")
    expect_equal(typeof(res$handle), "externalptr")
    expect_equal(res$correlation_id, cid)
    expect_true(is.na(res$detail))

    st <- runix:::.effect_session_state(res$handle)
    expect_equal(st$state, "opened")
    expect_equal(st$correlation_id, cid)
    expect_true(st$has_receipt)
    expect_true(st$has_binding)
    expect_equal(st$owner_pid, Sys.getpid())

    ## THE custody property: neither secret is anywhere in the serialized handle
    ## (an external pointer's address is not serialized, and the tokens are only
    ## in C heap). The test knows the exact minted tokens, so their absence is a
    ## real check, not a tautology.
    ser <- serialize(res$handle, NULL)
    expect_equal(length(grepRaw(charToRaw(receipt), ser, fixed = TRUE)), 0L)
    expect_equal(length(grepRaw(charToRaw(binding), ser, fixed = TRUE)), 0L)

    ## a restored-from-disk handle loses its C address and is refused
    restored <- unserialize(serialize(res$handle, NULL))
    expect_error(runix:::.effect_session_state(restored),
                 "closed or was restored")

    ## the PID binding: the same handle used from a forked child is refused
    kid <- parallel::mcparallel(tryCatch({
        runix:::.effect_session_state(res$handle)
        "no-error"
    }, error = function(e) conditionMessage(e)))
    expect_true(grepl("another process", parallel::mccollect(kid)[[1]]))

    ## --- conns 2-6: open failure shapes never yield a session --------------
    ## a broker error response surfaces the code in detail, no handle
    e1 <- open_conn()
    expect_equal(e1$status, "broker_error")
    expect_equal(e1$detail, "schema_invalid")
    expect_null(e1$handle)
    ## an out-of-contract error code is itself malformed -> bad_response
    expect_equal(open_conn()$status, "bad_response")
    ## an open_ok WITHOUT the effect_receipt (5 keys) is not open_ok_effect
    expect_equal(open_conn()$status, "bad_response")
    ## effect_receipt equal to the binding is a malformed response
    expect_equal(open_conn()$status, "bad_response")
    ## a non-system audit_scope never yields a session
    expect_equal(open_conn()$status, "bad_response")

    ## --- conn 7: write_outcome on the still-open session -------------------
    wo <- write_conn(res$handle, list(outcome = "ok", effect_issued = TRUE))
    parallel::mccollect(broker)
    expect_equal(wo$status, "ok")
    expect_true(is.na(wo$detail))

    ## the binding is spent and wiped; the receipt (commit path, later) remains;
    ## the session is closed and refuses a second outcome (no connection made)
    st2 <- runix:::.effect_session_state(res$handle)
    expect_equal(st2$state, "closed")
    expect_false(st2$has_binding)
    expect_true(st2$has_receipt)
    expect_error(runix:::.effect_session_write_outcome(res$handle,
                                                       list(outcome = "ok")),
                 "already written")
}
