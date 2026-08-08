#!/usr/bin/env r
## rctl launcher parity, per docs/rctl-json-contract.md: identical
## invocations through the littler launcher and the Rscript fallback must
## produce byte-identical stdout — including error envelopes. Launchers
## are exec'd via their shebangs, i.e. the real installed path.
##
##     r integration-tests/rctl-launcher-parity.R

stopifnot(requireNamespace("rctl", quietly = TRUE))
lr <- system.file("bin", "rctl", package = "rctl")
rs <- system.file("bin", "rctl-rscript", package = "rctl")
stopifnot(nzchar(lr), nzchar(rs))
Sys.chmod(c(lr, rs), "0755")

run <- function(bin, args) {
    out <- suppressWarnings(system2(bin, args, stdout = TRUE,
        stderr = FALSE))
    paste(as.character(out), collapse = "\n")
}

cases <- list(
    c("capabilities", "--json"),
    c("packages", "cache-timestamps", "--json"),
    c("no", "such", "operation", "--json")
)

ok <- TRUE
for (args in cases) {
    a <- run(lr, args)
    b <- run(rs, args)
    same <- identical(a, b)
    cat(sprintf("%-45s %s\n", paste(args, collapse = " "),
        if (same) "byte-identical" else "MISMATCH"))
    if (!same) {
        cat("littler: ", a, "\nRscript: ", b, "\n")
        ok <- FALSE
    }
}

if (ok) {
    cat("rctl-launcher-parity: all ", length(cases),
        " cases byte-identical\n", sep = "")
} else {
    quit(status = 1L)
}
