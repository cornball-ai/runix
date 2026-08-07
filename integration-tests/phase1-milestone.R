#!/usr/bin/env r
## Phase 1 cross-package acceptance: PLAN.md's first concrete milestone,
## exercised across rdpkg and rsystemd together. Lives in the umbrella repo
## because subsystem packages must not depend on each other.
##
##     r integration-tests/phase1-milestone.R
##
## Live-system checks; exits non-zero on any failure.

stopifnot(
    requireNamespace("rdpkg", quietly = TRUE),
    requireNamespace("rsystemd", quietly = TRUE)
)

check <- function(label, expr) {
    ok <- isTRUE(tryCatch(expr, error = function(e) {
        message(label, ": ", conditionMessage(e))
        FALSE
    }))
    cat(sprintf("%-55s %s\n", label, if (ok) "ok" else "FAIL"))
    ok
}

results <- c(
    check("apt_upgradable() returns the contracted frame", {
        up <- rdpkg::apt_upgradable()
        identical(names(up), c("package", "installed", "candidate",
            "origin", "site", "suite", "component", "security",
            "phased_percent"))
    }),
    check("dpkg_installed() sees dpkg itself",
        "dpkg" %in% rdpkg::dpkg_installed()$package),
    check("apt_policy('dpkg') explains resolution", {
        p <- rdpkg::apt_policy("dpkg")
        p$installed == p$candidate && nrow(p$versions) >= 1L
    }),
    check("apt_cache_timestamps() has real stamps", {
        ts <- rdpkg::apt_cache_timestamps()
        !is.na(ts$lists_updated) && !is.na(ts$status_changed)
    }),
    check("systemd_units() sees the root mount",
        "-.mount" %in% rsystemd::systemd_units()$unit),
    check("systemd_journal(priority = 3) respects the filter", {
        logs <- rsystemd::systemd_journal(priority = 3L, n = 50L)
        all(stats::na.omit(logs$priority) <= 3L)
    }),
    check("systemd_timers() joins unit state", {
        tm <- rsystemd::systemd_timers()
        nrow(tm) > 0L && any(!is.na(tm$active_state))
    }),
    check("systemd_state() coherent with failed units", {
        st <- rsystemd::systemd_state()
        st$state %in% c("running", "degraded", "maintenance", "starting") &&
            (st$state != "running" || length(st$failed_units) == 0L)
    }),
    check("cross-package: installed unattended-upgrades has its unit", {
        have <- "unattended-upgrades" %in% rdpkg::dpkg_installed()$package
        if (have) {
            info <- rsystemd::systemd_unit_info("unattended-upgrades.service")
            info$load_state == "loaded"
        } else {
            TRUE
        }
    })
)

if (all(results)) {
    cat("phase1-milestone: all ", length(results), " checks passed\n",
        sep = "")
} else {
    cat("phase1-milestone: ", sum(!results), " of ", length(results),
        " checks FAILED\n", sep = "")
    quit(status = 1L)
}
