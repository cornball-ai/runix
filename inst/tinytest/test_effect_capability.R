# effect_capability(): the broker effect-receipt negotiation gate (R/effect_
# capability.R). The exported entry pins the broker peer to root; the internal
# .effect_capability() takes an expected uid so these drive the logic against an
# unprivileged fake broker. Every byte the client reads is a frame this test
# builds and a fake broker serves verbatim.

## ---- argument validation (no server) -------------------------------------
expect_error(runix:::.effect_capability(tempfile(), plan_schema = 0L),
             ">= 1")
expect_error(runix:::.effect_capability(tempfile(), plan_schema = c(1L, 2L)),
             "single integer value")
expect_error(runix:::.effect_capability(tempfile(), plan_schema = NA_integer_),
             "single integer value")
## a fractional schema is rejected, never silently truncated to 1
expect_error(runix:::.effect_capability(tempfile(), plan_schema = 1.5),
             "single integer value")
expect_error(runix:::.effect_capability(tempfile(), connect_ms = 200.5),
             "single integer value")

## ---- an unreachable broker fails closed, typed --------------------------
e <- tryCatch(effect_capability(tempfile(fileext = ".sock"), connect_ms = 200L),
              condition = function(c) c)
expect_true(inherits(e, "runix_capability_unavailable"))
expect_true(inherits(e, "runix_error"))
expect_equal(e$reason, "broker unreachable or untrusted")
expect_equal(e$transport, "runix_broker_unavailable")
expect_equal(e$plan_schema, 1L)

## ---- fake broker: the four negotiation outcomes -------------------------
is_linux <- identical(Sys.info()[["sysname"]], "Linux")
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

    ## exact wire bytes -- a capabilities response is a fixed shape; hand-writing
    ## the JSON controls every byte and avoids depending on the encoder's object
    ## vs array choice for an empty extensions map.
    caps_full <- paste0('{"ok":true,"frame_version":1,',
                        '"record_schema_version":1,',
                        '"extensions":{"effect_receipt":1},"plan_schemas":[1]}')
    caps_noext <- paste0('{"ok":true,"frame_version":1,',
                         '"record_schema_version":1,',
                         '"extensions":{},"plan_schemas":[1]}')
    caps_schema2 <- paste0('{"ok":true,"frame_version":1,',
                           '"record_schema_version":1,',
                           '"extensions":{"effect_receipt":1},',
                           '"plan_schemas":[2]}')
    caps_v2 <- paste0('{"ok":true,"frame_version":1,',
                      '"record_schema_version":1,',
                      '"extensions":{"effect_receipt":2},"plan_schemas":[1]}')
    err_unknown <- '{"ok":false,"error":"unknown_request","message":"x"}'

    sock <- tempfile("fake-cap-")
    broker <- parallel::mcparallel(runix:::.broker_test_serve_seq(sock, list(
        frame_json(caps_full),    # conn 1: full support -> capability object
        frame_json(caps_noext),   # conn 2: no effect_receipt extension
        frame_json(caps_schema2), # conn 3: plan_schema 1 not offered
        frame_json(caps_v2),      # conn 4: extension version 2, not this client
        frame_json(err_unknown)   # conn 5: broker does not know the query
    ), read_first = TRUE))

    cap_call <- function() {
        r <- structure(list(), class = "unavailable_marker")
        for (attempt in 1:600) {
            if (file.exists(sock)) {
                r <- tryCatch(
                    runix:::.effect_capability(sock, plan_schema = 1L,
                                               expected_uid = myuid,
                                               connect_ms = 500L),
                    condition = function(c) c)
                ## an "unavailable" transport means the server has not bound yet;
                ## keep retrying. Any other outcome (success or a different
                ## typed failure) is the scripted reply.
                if (!(inherits(r, "runix_capability_unavailable") &&
                      identical(r$transport, "runix_broker_unavailable"))) {
                    break
                }
            }
            Sys.sleep(0.02)
        }
        r
    }

    ## conn 1: full negotiation succeeds -> a capability object, no condition
    cap <- cap_call()
    expect_true(inherits(cap, "runix_effect_capability"))
    expect_equal(cap$effect_receipt, 1L)
    expect_equal(cap$plan_schema, 1L)
    expect_equal(cap$plan_schemas, 1L)
    expect_equal(cap$frame_version, 1L)

    ## conn 2: extension absent -> fail closed, named
    c2 <- cap_call()
    expect_true(inherits(c2, "runix_capability_unavailable"))
    expect_true(grepl("does not advertise", conditionMessage(c2)))

    ## conn 3: required plan schema not offered -> fail closed, carries offer
    c3 <- cap_call()
    expect_true(inherits(c3, "runix_capability_unavailable"))
    expect_true(grepl("does not accept plan_schema", conditionMessage(c3)))
    expect_equal(c3$plan_schemas, 2L)

    ## conn 4: the advertised extension version is not the one this client
    ## implements -> fail closed, carries the offered version (strict, not >=1)
    c4 <- cap_call()
    expect_true(inherits(c4, "runix_capability_unavailable"))
    expect_true(grepl("version", conditionMessage(c4)))
    expect_equal(c4$extension_version, 2L)

    ## conn 5: broker does not know the capabilities query -> fail closed
    c5 <- cap_call()
    expect_true(inherits(c5, "runix_capability_unavailable"))
    expect_equal(c5$broker, "unknown_request")

    parallel::mccollect(broker)
}
