# retryability registry: register + query, no class-string reconstruction.

# a fresh unregistered class is not retryable
e <- structure(class = c("demo_unregistered", "runix_error", "error",
    "condition"), list(message = "x"))
expect_false(is_retryable(e))

register_retryable("demo_retry_a", "demo_retry_b")
ra <- structure(class = c("demo_retry_a", "runix_error", "error",
    "condition"), list(message = "x"))
expect_true(is_retryable(ra))
rb <- structure(class = c("demo_retry_b", "runix_error", "error",
    "condition"), list(message = "x"))
expect_true(is_retryable(rb))

# idempotent registration
before <- register_retryable("demo_retry_a")
after <- register_retryable("demo_retry_a")
expect_equal(before, after)

# unregistered still false after others registered
expect_false(is_retryable(e))
