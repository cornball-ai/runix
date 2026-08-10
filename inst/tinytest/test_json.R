## encode_json_line: types, escaping, determinism, single-line guarantee.

expect_equal(encode_json_line(list(a = 1L, b = "x", c = TRUE, d = NA)),
             '{"a":1,"b":"x","c":true,"d":null}')
expect_equal(encode_json_line(list(x = 0.5)), '{"x":0.5}')
expect_equal(encode_json_line(list(n = 90L)), '{"n":90}')
expect_equal(encode_json_line(list(preview = FALSE)), '{"preview":false}')
expect_equal(encode_json_line(NULL), "null")

## object key order follows list order (deterministic)
expect_equal(encode_json_line(list(b = 1L, a = 2L)), '{"b":1,"a":2}')
expect_equal(encode_json_line(list(o = list(active = "yes", sub = "run"))),
             '{"o":{"active":"yes","sub":"run"}}')

## arrays
expect_equal(encode_json_line(list(v = c("a", "b"))), '{"v":["a","b"]}')
expect_equal(encode_json_line(list(v = c(1L, 2L, 3L))), '{"v":[1,2,3]}')

## POSIXct -> ISO-8601 Z
t <- as.POSIXct("2026-08-08 12:00:00", tz = "UTC")
expect_equal(encode_json_line(list(t = t)), '{"t":"2026-08-08T12:00:00Z"}')

## never emits an embedded newline (one record == one JSONL line)
expect_false(grepl("\n", encode_json_line(list(s = "a\nb")), fixed = TRUE))
expect_false(grepl("\r", encode_json_line(list(s = "a\rb")), fixed = TRUE))

## fail-closed surface: unsupported type, non-finite, duplicate keys, depth
expect_error(encode_json_line(list(f = function() 1)))
expect_error(encode_json_line(list(x = Inf)))
expect_error(encode_json_line(list(x = NaN)))
expect_error(encode_json_line(list(a = 1L, a = 2L)))   # duplicate object keys

deep <- 1L
for (i in 1:80) deep <- list(x = deep)
expect_error(encode_json_line(deep, max_depth = 64L))  # too deep
expect_false(grepl("\n",
    encode_json_line(list(a = list(b = list(c = 1L)))), fixed = TRUE))  # ok depth

## invalid UTF-8 is rejected, not emitted
bad <- "\xff\xfe"
Encoding(bad) <- "UTF-8"
expect_error(encode_json_line(list(s = bad)))

## escaping round-trips through a real parser
if (requireNamespace("janssonr", quietly = TRUE)) {
    rt <- function(x) janssonr::from_json(encode_json_line(x))
    s <- "line1\nline2\ttab \"q\" back\\slash  café"
    expect_equal(rt(list(s = s))$s, s)
    got <- rt(list(a = 1L, b = TRUE, c = NA, d = 0.25))
    expect_equal(got$a, 1L)
    expect_true(got$b)
    expect_true(is.null(got$c))   # JSON null round-trips to NULL under janssonr
    expect_equal(got$d, 0.25)
    ## nested + array round-trip; janssonr maps a JSON array to an unnamed list
    nested <- list(op = "x", observed = list(state = "active"), tags = c("a", "b"))
    back <- rt(nested)
    expect_equal(back$observed$state, "active")
    expect_equal(back$tags, list("a", "b"))
}
