#' Encode an R value as a single-line JSON string
#'
#' A small, dependency-free, deterministic JSON encoder for audit records and
#' similar flat-to-shallow data, so the `runix` core can persist JSONL without
#' pulling in an encoder dependency. Object keys follow the insertion order of
#' the named list (deterministic), and the output contains no newlines, so one
#' record is exactly one JSONL line. It is **not** a general-purpose encoder
#' and is deliberately **fail-closed** on a narrow type surface: it models the
#' types audit records use (character, numeric, integer, logical, `NULL`,
#' `NA`, `POSIXct`, and named/unnamed lists) and errors on anything it cannot
#' model correctly (unsupported classes, non-finite numbers, invalid UTF-8,
#' duplicate object keys, nesting beyond `max_depth`) rather than emit
#' something wrong. A consumer that needs a fuller or faster encoder (e.g.
#' `yyjsonr`) can inject it wherever this is used.
#'
#' @param x Value to encode: a scalar, an atomic vector, or a possibly nested
#'   list. Named lists become JSON objects (insertion order); unnamed
#'   vectors/lists become arrays; a length-1 unnamed atomic becomes a
#'   primitive. `NA` and `NULL` become JSON `null`. `POSIXct` becomes an
#'   ISO-8601 UTC string.
#' @param max_depth Maximum container nesting depth; deeper structures are
#'   rejected rather than encoded (guards against pathological records).
#' @return A length-1 character string of JSON with no embedded newlines.
#' @examples
#' encode_json_line(list(a = 1L, b = "x", c = TRUE, d = NA))
#' @export
encode_json_line <- function(x, max_depth = 64L) {
    out <- .json_value(x, 1L, max_depth)
    if (grepl("\n", out, fixed = TRUE) || grepl("\r", out, fixed = TRUE)) {
        stop("encoded JSON contains a newline")
    }
    out
}

.json_value <- function(x, depth, max_depth) {
    if (depth > max_depth) {
        stop("JSON nesting exceeds max_depth (", max_depth, ")")
    }
    if (is.null(x)) {
        return("null")
    }
    if (inherits(x, "POSIXct")) {
        return(.json_string(.iso8601_utc(x)))
    }
    if (is.list(x)) {
        return(.json_container(x, depth, max_depth))
    }
    n <- length(x)
    if (n == 0L) {
        return("[]")
    }
    if (is.null(names(x)) && n == 1L) {
        return(.json_scalar(x, depth, max_depth))
    }
    if (!is.null(names(x))) {
        return(.json_container(as.list(x), depth, max_depth))
    }
    parts <- vapply(seq_len(n),
                    function(i) .json_scalar(x[i], depth, max_depth),
                    character(1))
    paste0("[", paste(parts, collapse = ","), "]")
}

## A named list -> object (keys in list order, no duplicates); an unnamed
## list -> array.
.json_container <- function(x, depth, max_depth) {
    if (length(x) == 0L) {
        if (is.null(names(x))) {
            return("[]")
        } else {
            return("{}")
        }
    }
    nms <- names(x)
    if (is.null(nms)) {
        parts <- vapply(x, function(e) .json_value(e, depth + 1L, max_depth),
                        character(1))
        return(paste0("[", paste(parts, collapse = ","), "]"))
    }
    if (any(nms == "")) {
        stop("cannot encode a partially-named list as a JSON object")
    }
    if (anyDuplicated(nms)) {
        stop("duplicate object keys: ",
             paste(unique(nms[duplicated(nms)]), collapse = ", "))
    }
    parts <- vapply(seq_along(x), function(i) {
        paste0(.json_string(nms[i]), ":",
               .json_value(x[[i]], depth + 1L, max_depth))
    }, character(1))
    paste0("{", paste(parts, collapse = ","), "}")
}

## A length-1 atomic (or a bare list element) -> a JSON primitive.
.json_scalar <- function(x, depth, max_depth) {
    if (is.null(x)) {
        return("null")
    }
    if (is.list(x)) {
        return(.json_value(x[[1L]], depth, max_depth))
    }
    if (length(x) == 0L) {
        return("null")
    }
    if (inherits(x, "POSIXct")) {
        return(.json_string(.iso8601_utc(x)))
    }
    if (is.double(x)) {
        ## non-finite is rejected; typed NA_real_ is a legitimate null
        if (is.nan(x)) {
            stop("cannot encode NaN in JSON")
        }
        if (is.infinite(x)) {
            stop("cannot encode a non-finite number in JSON")
        }
        if (is.na(x)) {
            return("null")
        }
        return(.json_number(x))
    }
    if (is.na(x)) {
        return("null")
    }
    if (is.logical(x)) {
        return(if (isTRUE(x)) "true" else "false")
    }
    if (is.character(x)) {
        return(.json_string(x))
    }
    if (is.integer(x)) {
        return(as.character(x))
    }
    stop("cannot encode value of type ", typeof(x))
}

.json_number <- function(x) {
    if (!is.finite(x)) {
        stop("cannot encode a non-finite number in JSON")
    }
    format(x, scientific = FALSE, trim = TRUE, digits = 15)
}

.iso8601_utc <- function(t) {
    attr(t, "tzone") <- "UTC"
    format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
}

.json_string <- function(s) {
    s <- enc2utf8(as.character(s))
    if (!isTRUE(validUTF8(s))) {
        stop("cannot encode invalid UTF-8 in a JSON string")
    }
    s <- gsub("\\", "\\\\", s, fixed = TRUE)
    s <- gsub("\"", "\\\"", s, fixed = TRUE)
    s <- gsub("\b", "\\b", s, fixed = TRUE)
    s <- gsub("\f", "\\f", s, fixed = TRUE)
    s <- gsub("\n", "\\n", s, fixed = TRUE)
    s <- gsub("\r", "\\r", s, fixed = TRUE)
    s <- gsub("\t", "\\t", s, fixed = TRUE)
    s <- .json_escape_control(s)
    paste0("\"", s, "\"")
}

## Escape any remaining C0 control characters (< 0x20) as \u00XX. The common
## ones (\b \f \n \r \t) are already handled above; this catches the rest.
.json_escape_control <- function(s) {
    ints <- utf8ToInt(s)
    if (!any(ints < 32L)) {
        return(s)
    }
    parts <- vapply(ints, function(cp) {
        if (cp < 32L) {
            sprintf("\\u%04x", cp)
        } else {
            intToUtf8(cp)
        }
    }, character(1))
    paste0(parts, collapse = "")
}
