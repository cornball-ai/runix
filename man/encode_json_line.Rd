% tinyrox says don't edit this manually, but it can't stop you!
\name{encode_json_line}
\alias{encode_json_line}
\title{Encode an R value as a single-line JSON string}
\usage{
encode_json_line(x)
}
\arguments{
\item{x}{Value to encode: a scalar, an atomic vector, or a possibly nested
list. Named lists become JSON objects (insertion order); unnamed
vectors/lists become arrays; a length-1 unnamed atomic becomes a
primitive. `NA` and `NULL` become JSON `null`. `POSIXct` becomes an
ISO-8601 UTC string.}
}
\value{
A length-1 character string of JSON with no embedded newlines.
}
\description{
A small, dependency-free, deterministic JSON encoder for audit records and
similar flat-to-shallow data, so the `runix` core can persist JSONL without
pulling in an encoder dependency. Object keys follow the insertion order of
the named list (deterministic), and the output contains no newlines, so one
record is exactly one JSONL line. It is **not** a general-purpose encoder:
it models the types audit records use (character, numeric, integer,
logical, `NULL`, `NA`, `POSIXct`, and named/unnamed lists) and errors on
anything else rather than emit something wrong. A consumer that needs a
fuller or faster encoder (e.g. `yyjsonr`) can inject it wherever this is
used.
}
\examples{
encode_json_line(list(a = 1L, b = "x", c = TRUE, d = NA))
}
