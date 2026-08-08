# new_runix_result: neutral shape, subclassing, NA-tolerant fields, print.

r <- new_runix_result("systemd.restart", "cups.service", changed = TRUE,
    state_changed = TRUE, preview = FALSE,
    before = list(active_state = "active"),
    after = list(active_state = "active"),
    planned = list(effect_would_issue = TRUE),
    completion = list(method = "invocation_id"),
    audit = list(outcome = "ok"),
    subclass = "systemd_result")

expect_inherits(r, "systemd_result")
expect_inherits(r, "runix_result")
expect_equal(r$operation, "systemd.restart")
expect_equal(r$completion$method, "invocation_id")
expect_equal(r$audit$outcome, "ok")

# NA changed/state_changed (submitted-but-unconfirmed) is allowed
r2 <- new_runix_result("systemd.restart", "x", changed = NA,
    state_changed = NA, preview = FALSE, before = list(), after = list(),
    planned = list(), completion = list(method = "submitted_unconfirmed"),
    audit = list(outcome = "submitted"))
expect_true(is.na(r2$changed))
expect_equal(class(r2), "runix_result")  # no subclass -> bare

# print is non-erroring and marks previews
out <- capture.output(print(r))
expect_true(any(grepl("systemd.restart cups.service: changed=TRUE", out)))
rp <- new_runix_result("demo.op", "t", changed = FALSE,
    state_changed = FALSE, preview = TRUE, before = list(), after = NA,
    planned = list(), completion = list(), audit = list())
out <- capture.output(print(rp))
expect_true(any(grepl("[preview]", out, fixed = TRUE)))
