# runix_abort: taxonomy tail, subclass prepend, data merge.

e <- tryCatch(
    runix_abort("boom", subclass = c("pkgstate_cache_race", "pkgstate_error")),
    error = identity)
expect_inherits(e, "pkgstate_cache_race")
expect_inherits(e, "pkgstate_error")
expect_inherits(e, "runix_error")
expect_inherits(e, "error")
expect_equal(conditionMessage(e), "boom")
# canonical tail order, most-specific first
expect_equal(class(e)[1:4],
    c("pkgstate_cache_race", "pkgstate_error", "runix_error", "error"))

# data fields merge onto the condition
e <- tryCatch(
    runix_abort("t", subclass = "rsystemd_error",
        data = list(resource = "x.service", elapsed = 1.5,
            observed = list(active_state = "failed"))),
    error = identity)
expect_equal(e$resource, "x.service")
expect_equal(e$elapsed, 1.5)
expect_equal(e$observed$active_state, "failed")

# no subclass -> just the canonical tail
e <- tryCatch(runix_abort("bare"), error = identity)
expect_equal(class(e), c("runix_error", "error", "condition"))

# data must be a list
expect_error(runix_abort("t", data = "notalist"))
