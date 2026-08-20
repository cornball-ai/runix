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

    ## ---- commit-path availability (re-review Finding: fail-closed) ---------
    ## When the atomic child-side fd-close primitive is absent
    ## (-DRUNIX_NO_CLOSEFROM_NP), commit is refused fail-closed rather than
    ## spawned with an unbounded fd set. The platform guard is the FIRST thing
    ## commit does, so the refusal is checkable with any argument (no session).
    ## This build has the primitive, so the branch is skipped here; it fires in a
    ## no-primitive build's suite.
    if (!runix:::.effect_session_commit_supported()) {
        expect_error(runix:::.effect_session_commit("not a handle", "nginx"),
                     "unavailable on this platform")
    }
}

## ---- fake broker: open / write_outcome / state / commit ------------------
## The broker peer uid the transport authenticates is PINNED to root (0) in the
## production build; a testing build (-DRUNIX_TESTING) reads RUNIX_TEST_PEER_UID
## so an unprivileged fake broker can be exercised. There is no R-facing knob.
## Consequently: the production build can only prove the PINNING (a non-root
## broker is refused), while the full open/write_outcome/commit flow runs in the
## testing build against a fake broker owned by this user.
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

    ## ---- PRODUCTION build: uid-0 pinning refuses a non-root broker --------
    ## The shipped build pins the peer to root; a fake broker owned by this
    ## (unprivileged) user is refused as untrusted BEFORE any request byte is
    ## sent. This is the Finding-1 regression: nothing R passes can lower the
    ## bar. Skip when running as root -- then a root broker is legitimately
    ## accepted and refusal cannot be demonstrated.
    if (!runix:::.effect_session_testing() && myuid != 0L) {
        psock <- tempfile("fake-es-pin-")
        pbroker <- parallel::mcparallel(runix:::.broker_test_serve_seq(
            psock, list(frame_json(open_ok_effect)), read_first = TRUE))
        pr <- list(status = "unavailable")
        for (attempt in 1:600) {
            if (file.exists(psock)) {
                pr <- runix:::.effect_session_open(psock, "apt.install", "nginx",
                    1L, plan_hash, connect_ms = 500L)
                if (!identical(pr$status, "unavailable")) break
            }
            Sys.sleep(0.02)
        }
        parallel::mccollect(pbroker)
        expect_equal(pr$status, "untrusted_peer")
        expect_null(pr$handle)
    }

    ## ---- TESTING build: full open / write_outcome / state flow ------------
    if (runix:::.effect_session_testing()) {
    old_peer <- Sys.getenv("RUNIX_TEST_PEER_UID", unset = NA)
    Sys.setenv(RUNIX_TEST_PEER_UID = myuid)
    on.exit({
        if (is.na(old_peer)) {
            Sys.unsetenv("RUNIX_TEST_PEER_UID")
        } else {
            Sys.setenv(RUNIX_TEST_PEER_UID = old_peer)
        }
    }, add = TRUE)

    ## ONE long-lived broker answers EVERY connection this test makes, in order,
    ## modelling a real broker (one path, many requests). This deliberately
    ## avoids forking a fresh server per exchange: under the test harness,
    ## mcparallel fork latency degrades after several forks and a late-binding
    ## server misses its client. The reply order below is the connection order.
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
                    1L, plan_hash)
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

    ## --- commit: the pkexec-entrypoint spawn (compile-time seam only) -------
    ## a fake entrypoint: dump the stdin request (which carries the receipt) and
    ## argv (the entrypoint path), optionally sleep (to force a read timeout),
    ## then emit a chosen result on stdout and exit with a chosen code --
    ## mimicking the real fd protocol.
    fake <- tempfile("fake-entry-", fileext = ".sh")
    writeLines(c(
        "#!/bin/sh",
        "cat > \"$RUNIX_TEST_REQ_DUMP\"",
        "printf '%s\\n' \"$@\" > \"$RUNIX_TEST_ARGV_DUMP\"",
        ## fd-hygiene probe: record whether the parent's leak-sentinel fd was
        ## inherited (its symlink target visible in /proc/self/fd)
        paste0("if [ -n \"$RUNIX_TEST_SENTINEL_PATH\" ]; then ",
               ": > \"$RUNIX_TEST_SENTINEL_DUMP\"; ",
               "for f in /proc/self/fd/*; do ",
               "[ \"$(readlink \"$f\" 2>/dev/null)\" = \"$RUNIX_TEST_SENTINEL_PATH\" ]",
               " && echo LEAKED >> \"$RUNIX_TEST_SENTINEL_DUMP\"; done; fi"),
        "[ -n \"$RUNIX_TEST_SLEEP\" ] && sleep \"$RUNIX_TEST_SLEEP\"",
        "[ -n \"$RUNIX_TEST_RESULT\" ] && printf '%s' \"$RUNIX_TEST_RESULT\"",
        "exit \"${RUNIX_TEST_EXIT:-0}\""), fake)
    Sys.chmod(fake, "0755")
    req_dump <- tempfile("req-")
    argv_dump <- tempfile("argv-")
    Sys.setenv(RUNIX_TEST_ENTRYPOINT = fake, RUNIX_TEST_REQ_DUMP = req_dump,
               RUNIX_TEST_ARGV_DUMP = argv_dump)
    on.exit(Sys.unsetenv(c("RUNIX_TEST_ENTRYPOINT", "RUNIX_TEST_REQ_DUMP",
                           "RUNIX_TEST_ARGV_DUMP", "RUNIX_TEST_RESULT",
                           "RUNIX_TEST_EXIT", "RUNIX_TEST_SLEEP",
                           "RUNIX_TEST_SENTINEL_PATH", "RUNIX_TEST_SENTINEL_DUMP",
                           "RUNIX_TEST_FORCE_UNDELIVERED")), add = TRUE)

    ## precondition: this build supports the commit path (an atomic fd-close
    ## primitive is present). The commit tests below assume it; a build without
    ## it (-DRUNIX_NO_CLOSEFROM_NP) refuses commit fail-closed and is exercised
    ## separately.
    expect_true(runix:::.effect_session_commit_supported())

    result_ok <- runix:::encode_json_line(list(
        status = "ok", effect_issued = TRUE, correlation_id = cid, detail = ""))
    result_held <- runix:::encode_json_line(list(
        status = "held", effect_issued = FALSE, correlation_id = cid,
        detail = "held back"))
    result_long <- runix:::encode_json_line(list(
        status = "ok", effect_issued = TRUE, correlation_id = cid,
        detail = strrep("d", 200)))       # detail > 128: a malformed result

    csock <- tempfile("fake-es-c")
    ## connection order below == reply order; every open consumes one reply,
    ## every write_outcome one; a commit uses the fake entrypoint, not the broker;
    ## a commit rejected during input validation consumes nothing.
    cbroker <- parallel::mcparallel(runix:::.broker_test_serve_seq(csock, list(
        frame_json(open_ok_effect), # 1  s1 open (happy)
        frame_json(outcome_ok),     # 2  s1 write_outcome
        frame_json(open_ok_effect), # 3  s2 open (empty result -> unknown)
        frame_json(open_ok_effect), # 4  s3 open (exit 127 -> unauthorized)
        frame_json(open_ok_effect), # 5  s5 open (detail > 128 -> unknown)
        frame_json(open_ok_effect), # 6  s6 open (ok status, exit 1 -> unknown)
        frame_json(open_ok_effect), # 7  s7 open (held status, exit 1 -> ok/held)
        frame_json(open_ok_effect), # 8  s8 open (sleep past deadline -> unknown)
        frame_json(open_ok_effect), # 9  sund open (undelivered -> unknown)
        frame_json(open_ok_effect), # 10 sfd open (fd hygiene: closefrom primitive)
        frame_json(open_ok_effect), # 11 s4 open (bad entrypoint -> spawn_failed)
        frame_json(open_ok_effect), # 12 s_ins open (install: input-bound errors)
        frame_json(open_ok_effect)  # 13 s_upd open (update: arity error)
    ), read_first = TRUE))
    copen <- function(operation = "apt.install", resource = "nginx") {
        r <- list(status = "unavailable")
        for (a in 1:600) {
            if (file.exists(csock)) {
                r <- runix:::.effect_session_open(csock, operation, resource,
                    1L, plan_hash)
                if (!identical(r$status, "unavailable")) break
            }
            Sys.sleep(0.02)
        }
        r
    }

    ## happy path: the helper reports ok with effect_issued = TRUE
    Sys.setenv(RUNIX_TEST_RESULT = result_ok)
    Sys.unsetenv("RUNIX_TEST_EXIT")
    s1 <- copen()
    expect_equal(s1$status, "ok")
    c1 <- runix:::.effect_session_commit(s1$handle, packages = "nginx",
        lock_timeout = 30L, deadline_ms = 5000L)
    expect_equal(c1$session_status, "ok")
    expect_equal(c1$status, "ok")
    expect_true(isTRUE(c1$effect_issued))
    expect_equal(c1$correlation_id, cid)

    ## the receipt was DELIVERED to the child (its request dump has it) and the
    ## exact contracted request fields are present
    reqbytes <- readChar(req_dump, file.info(req_dump)$size, useBytes = TRUE)
    expect_true(grepl(receipt, reqbytes, fixed = TRUE))
    expect_true(grepl("\"correlation_id\":\"", reqbytes, fixed = TRUE))
    expect_true(grepl("\"plan_schema\":1", reqbytes, fixed = TRUE))
    expect_true(grepl("\"lock_timeout\":30", reqbytes, fixed = TRUE))
    expect_true(grepl("\"nginx\"", reqbytes, fixed = TRUE))
    ## and it was WIPED from the session after delivery
    st_c <- runix:::.effect_session_state(s1$handle)
    expect_equal(st_c$state, "result_known")
    expect_false(st_c$has_receipt)
    ## the verb mapped to its immutable entrypoint path (no path from R)
    expect_true(any(grepl("/usr/libexec/pkgexec/runix-apt-install",
                          readLines(argv_dump), fixed = TRUE)))
    ## the outcome still closes over the broker (conn 2)
    wo1 <- runix:::.effect_session_write_outcome(s1$handle,
        list(outcome = "ok", effect_issued = TRUE))
    expect_equal(wo1$status, "ok")

    ## a child that runs but emits no valid result: the effect is UNKNOWN
    Sys.setenv(RUNIX_TEST_RESULT = "")
    Sys.unsetenv("RUNIX_TEST_EXIT")
    s2 <- copen()
    c2 <- runix:::.effect_session_commit(s2$handle, packages = "nginx",
        deadline_ms = 5000L)
    expect_equal(c2$session_status, "effect_unknown")
    expect_true(is.na(c2$effect_issued))
    expect_equal(runix:::.effect_session_state(s2$handle)$state, "effect_unknown")

    ## pkexec-style denial (exit 127, no result): unauthorized, no effect
    Sys.setenv(RUNIX_TEST_RESULT = "", RUNIX_TEST_EXIT = "127")
    s3 <- copen()
    c3 <- runix:::.effect_session_commit(s3$handle, packages = "nginx",
        deadline_ms = 5000L)
    expect_equal(c3$session_status, "unauthorized")
    expect_equal(c3$effect_issued, FALSE)

    ## a result whose detail exceeds 128 bytes is malformed -> effect UNKNOWN
    ## (Finding 4: the parser refuses to truncate an over-long detail)
    Sys.setenv(RUNIX_TEST_RESULT = result_long)
    Sys.unsetenv("RUNIX_TEST_EXIT")
    s5 <- copen()
    c5 <- runix:::.effect_session_commit(s5$handle, packages = "nginx",
        deadline_ms = 5000L)
    expect_equal(c5$session_status, "effect_unknown")
    expect_true(is.na(c5$effect_issued))

    ## an ok status with a NONZERO exit is a protocol violation -> UNKNOWN
    ## (Finding 4: exit code and status must agree; exit 0 iff ok/no_op)
    Sys.setenv(RUNIX_TEST_RESULT = result_ok, RUNIX_TEST_EXIT = "1")
    s6 <- copen()
    c6 <- runix:::.effect_session_commit(s6$handle, packages = "nginx",
        deadline_ms = 5000L)
    expect_equal(c6$session_status, "effect_unknown")
    expect_true(is.na(c6$effect_issued))

    ## a non-ok status (held) WITH a nonzero exit is consistent and trusted:
    ## the helper's status and effect_issued rule
    Sys.setenv(RUNIX_TEST_RESULT = result_held, RUNIX_TEST_EXIT = "1")
    s7 <- copen()
    c7 <- runix:::.effect_session_commit(s7$handle, packages = "nginx",
        deadline_ms = 5000L)
    expect_equal(c7$session_status, "ok")
    expect_equal(c7$status, "held")
    expect_equal(c7$effect_issued, FALSE)
    expect_equal(c7$detail, "held back")

    ## the child overruns the deadline (sleeps, emits nothing): SIGKILL and a
    ## genuinely indeterminate outcome -> effect UNKNOWN, never "did not run"
    ## (Finding 8: a late-completing privileged mutation is not a failure)
    Sys.setenv(RUNIX_TEST_RESULT = "", RUNIX_TEST_SLEEP = "3")
    Sys.unsetenv("RUNIX_TEST_EXIT")
    s8 <- copen()
    c8 <- runix:::.effect_session_commit(s8$handle, packages = "nginx",
        deadline_ms = 300L)
    expect_equal(c8$session_status, "effect_unknown")
    expect_true(is.na(c8$effect_issued))
    Sys.unsetenv("RUNIX_TEST_SLEEP")

    ## --- re-review Finding 1: a valid, cid-matching result is NOT trusted when
    ## the receipt was never delivered. The forced-undelivered seam skips the
    ## stdin write; the child still emits result_ok (which carries the known,
    ## fixed cid), yet the outcome must be effect UNKNOWN, not a trusted "ok".
    Sys.setenv(RUNIX_TEST_RESULT = result_ok, RUNIX_TEST_FORCE_UNDELIVERED = "1")
    Sys.unsetenv("RUNIX_TEST_EXIT")
    sund <- copen()
    cund <- runix:::.effect_session_commit(sund$handle, packages = "nginx",
        deadline_ms = 5000L)
    expect_equal(cund$session_status, "effect_unknown")
    expect_true(is.na(cund$effect_issued))
    Sys.unsetenv("RUNIX_TEST_FORCE_UNDELIVERED")

    ## --- re-review Finding 2: no inherited fd >= 3 leaks to the privileged
    ## child. R's own file-connection fds are NOT close-on-exec, so an open
    ## connection is a genuine leak sentinel. Assert (precondition) it really is
    ## non-CLOEXEC in the parent -- else the check would pass vacuously -- then
    ## assert the child never sees it, via the atomic in-child closefrom
    ## primitive (the only fd-close strategy the commit path now uses).
    sentinel_path <- tempfile("leak-sentinel-")
    sentinel_con <- file(sentinel_path, open = "wb")
    O_CLOEXEC <- strtoi("2000000", base = 8L) # 02000000 octal
    sentinel_leaky <- FALSE
    for (f in list.files("/proc/self/fd")) {
        if (identical(Sys.readlink(file.path("/proc/self/fd", f)), sentinel_path)) {
            fl <- readLines(file.path("/proc/self/fdinfo", f))
            oct <- strtoi(sub("flags:[[:space:]]*", "",
                              grep("^flags:", fl, value = TRUE)), base = 8L)
            sentinel_leaky <- bitwAnd(oct, O_CLOEXEC) == 0L
            break
        }
    }
    expect_true(sentinel_leaky) # precondition: the sentinel really can leak

    sentinel_dump <- tempfile("sentinel-dump-")
    Sys.setenv(RUNIX_TEST_RESULT = result_ok,
               RUNIX_TEST_SENTINEL_PATH = sentinel_path,
               RUNIX_TEST_SENTINEL_DUMP = sentinel_dump)
    Sys.unsetenv("RUNIX_TEST_EXIT")

    sfd <- copen()
    cfd <- runix:::.effect_session_commit(sfd$handle, packages = "nginx",
        deadline_ms = 5000L)
    expect_equal(cfd$session_status, "ok")
    leaked <- if (file.exists(sentinel_dump)) readLines(sentinel_dump) else character()
    expect_false(any(grepl("LEAKED", leaked)))
    close(sentinel_con)
    Sys.unsetenv(c("RUNIX_TEST_SENTINEL_PATH", "RUNIX_TEST_SENTINEL_DUMP"))

    ## a spawn that never execs (nonexistent entrypoint): provably no effect
    Sys.setenv(RUNIX_TEST_ENTRYPOINT = "/no/such/runix-entrypoint-xyzzy")
    Sys.unsetenv("RUNIX_TEST_EXIT")
    s4 <- copen()
    c4 <- runix:::.effect_session_commit(s4$handle, packages = "nginx",
        deadline_ms = 5000L)
    expect_true(c4$session_status %in% c("spawn_failed", "unauthorized"))
    expect_equal(c4$effect_issued, FALSE)

    ## --- Finding 5: the bounded request grammar is enforced BEFORE the
    ## single-use receipt is spent. Each rejected commit errors while the session
    ## stays OPENED (receipt still held), so ONE handle exercises them all.
    s_ins <- copen()  # apt.install
    expect_equal(runix:::.effect_session_state(s_ins$handle)$state, "opened")
    ## no packages for a package-taking verb
    expect_error(runix:::.effect_session_commit(s_ins$handle,
        packages = character()), "at least one package")
    ## an invalid name (uppercase), a leading dash (apt-option injection shape),
    ## and a duplicate are each refused
    expect_error(runix:::.effect_session_commit(s_ins$handle, packages = "Nginx"),
                 "invalid package name")
    expect_error(runix:::.effect_session_commit(s_ins$handle, packages = "-rf"),
                 "invalid package name")
    expect_error(runix:::.effect_session_commit(s_ins$handle,
        packages = c("nginx", "nginx")), "duplicate package")
    ## more than the entrypoint's cap of 256
    expect_error(runix:::.effect_session_commit(s_ins$handle,
        packages = paste0("pkg", seq_len(257))), "too many packages")
    ## every rejection left the receipt intact and the session open
    st_ins <- runix:::.effect_session_state(s_ins$handle)
    expect_equal(st_ins$state, "opened")
    expect_true(st_ins$has_receipt)

    ## a package-free verb (apt.update) refuses any package list
    s_upd <- copen(operation = "apt.update", resource = "system")
    expect_error(runix:::.effect_session_commit(s_upd$handle, packages = "nginx"),
                 "takes no packages")

    parallel::mccollect(cbroker)

    ## ---- REAL broker: the native open_intent + write_outcome FRAMES ----------
    ## The fake broker above validates NO schema, so a malformed native frame (a
    ## missing broker-required field, a rejected empty resource) slips through --
    ## exactly what the Part B VM gate caught. Drive the native C open +
    ## write_outcome against the ACTUAL broker daemon (the binary CI builds at
    ## RUNIX_TEST_BROKER_BIN) so those frames are validated for real. The peer uid
    ## is already unpinned to myuid above; skip when the binary is absent.
    rbin <- Sys.getenv("RUNIX_TEST_BROKER_BIN")
    if (nzchar(rbin) && file.exists(rbin)) {
        rdir <- tempfile("es-realbroker-")
        dir.create(rdir)
        rsock <- file.path(rdir, "sock")
        rsink <- file.path(rdir, "audit.jsonl")
        rpid <- suppressWarnings(system(sprintf(
            "%s --listen %s --sink %s >/dev/null 2>&1 & echo $!",
            shQuote(rbin), shQuote(rsock), shQuote(rsink)), intern = TRUE))
        rpid <- rpid[grepl("^[0-9]+$", rpid)][1]
        for (i in 1:200) {
            if (file.exists(rsock)) break
            Sys.sleep(0.02)
        }
        on.exit({
            if (length(rpid) == 1L && !is.na(rpid)) {
                system(paste("kill", rpid, "2>/dev/null"))
            }
            unlink(rdir, recursive = TRUE, force = TRUE)
        }, add = TRUE)
        expect_true(file.exists(rsock))
        rph <- strrep("e", 64)

        ## a WHOLE-SYSTEM verb carries an EMPTY resource -> ACCEPTED. Regresses both
        ## Part B open findings: the empty-resource rejection AND the missing
        ## broker-required `outcome` field in open_intent. A malformed frame comes
        ## back broker_error / bad_response, never status "ok" with a handle.
        ru <- runix:::.effect_session_open(rsock, "apt.update", "", 1L, rph)
        expect_equal(ru$status, "ok")
        expect_equal(typeof(ru$handle), "externalptr")
        expect_true(grepl("^[0-9]{20}-[0-9a-f]{16}$", ru$correlation_id))

        ## native write_outcome FRAME accepted end to end: a well-formed record
        ## (operation + the REQUIRED outcome) closes the intent. effect_issued=FALSE
        ## so the broker's effect-receipt gate needs no redemption.
        wu <- runix:::.effect_session_write_outcome(ru$handle,
            list(operation = "apt.update", outcome = "ok", effect_issued = FALSE))
        expect_equal(wu$status, "ok")

        ## a targeted verb still round-trips with a non-empty resource
        ri <- runix:::.effect_session_open(rsock, "apt.install", "nginx", 1L, rph)
        expect_equal(ri$status, "ok")

        ## NEGATIVE: a record OMITTING the broker-required `outcome` is REJECTED by
        ## the real broker -- proving the enforcement is real and this test actually
        ## guards the frame, not merely that the client did not error. A must-MATCH
        ## (the exact broker_error/schema_invalid pair) rather than a must-differ, so
        ## a transport slip cannot read as a false proof. The fake broker would have
        ## accepted it.
        rbad <- runix:::.effect_session_open(rsock, "apt.update", "", 1L, rph)
        expect_equal(rbad$status, "ok")
        wbad <- runix:::.effect_session_write_outcome(rbad$handle,
            list(operation = "apt.update", effect_issued = FALSE))
        expect_equal(wbad$status, "broker_error")
        expect_equal(wbad$detail, "schema_invalid")

        ## both phases of the good update landed durably in the real sink
        Sys.sleep(0.1)
        raud <- readLines(rsink, warn = FALSE)
        expect_true(any(grepl("\"phase\":\"intent\"", raud, fixed = TRUE)))
        expect_true(any(grepl("\"phase\":\"outcome\"", raud, fixed = TRUE)))
    }
    }
}
