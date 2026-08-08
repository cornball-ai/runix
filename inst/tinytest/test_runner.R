# new_runner: injection, per-instance state, env-agnostic core, typed
# missing-tool error, stderr capture.

rr <- new_runner(default_env = "LC_ALL=C",
    missing_tool_subclass = c("demo_missing_tool", "demo_error"))

# injection + restore
old <- rr$set_runner(function(cmd, args) {
    list(status = 0L, output = c("hi", cmd), stderr = character())
})
res <- rr$runner()("echo", "x")
expect_equal(res$output, c("hi", "echo"))
prev <- rr$set_runner(old)
# set_runner returns the previously-set value (our fake)
expect_true(is.function(prev))

# per-instance state: a second runner is independent
rr2 <- new_runner()
rr$set_runner(function(cmd, args) list(status = 42L, output = "a",
    stderr = character()))
expect_true(is.null(environment(rr2$runner)$state$run))
rr$set_runner(NULL)

# default executor: real command, stdout/stderr split
res <- rr$runner()("printf", shQuote("ok"))
expect_equal(res$status, 0L)
expect_true(any(grepl("ok", res$output)))

# missing tool -> typed error carrying the caller's subclass + resource
e <- tryCatch(rr$runner()("no-such-tool-xyzzy", character()),
    error = identity)
expect_inherits(e, "demo_missing_tool")
expect_inherits(e, "demo_error")
expect_inherits(e, "runix_error")
expect_equal(e$resource, "no-such-tool-xyzzy")

# sleeper injection (for poll loops)
rs <- new_runner()
expect_identical(rs$sleeper(), Sys.sleep)
rs$set_sleeper(function(t) stop("slept"))
expect_error(rs$sleeper()(0), pattern = "slept")
