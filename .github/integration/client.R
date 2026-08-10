## Integration gate, unprivileged-client half. Runs as the non-root CI user
## against the root, socket-activated broker daemon (installed from the .deb).
## Proves the whole chain: an unprivileged process obtains a SYSTEM-durable
## record it could not write itself, across a broker restart, and that the
## unavailable/untrusted paths never advertise system durability.
lib <- Sys.getenv("R_LIBS_INTEGRATION")
if (nzchar(lib)) {
    .libPaths(lib)
}
library(runix)

SOCK <- "/run/runix-audit.sock"                        # the systemd .socket path
BIN <- Sys.getenv("RAB_BROKER_BIN", "/usr/libexec/runix/audit-broker")

## capability probe: the runtime, root-authenticated check reports available,
## and system_durable_audit_available agrees -- from an unprivileged process,
## derived from the probe, not from a Boolean or the socket's mere existence.
stopifnot(identical(broker_available(SOCK), "available"),
          isTRUE(system_durable_audit_available(root = FALSE, socket_path = SOCK)))

## The broker runs as root (systemd), so the root-pinned public sink
## authenticates it (SO_PEERCRED uid 0) and earns "system".
s <- broker_audit_sink(socket_path = SOCK)
r <- s$open_intent(list(operation = "svc.restart", resource = "cups.service",
                        scope = "system", outcome = "intent",
                        effect_issued = FALSE))
stopifnot(isTRUE(r$persisted), identical(r$audit_scope, "system"),
          grepl("^[0-9a-f]{32}$", r$binding),
          grepl("^[0-9]{20}-[0-9a-f]{16}$", r$correlation_id))

## restart the broker while THIS R process stays alive: stop the running
## instance; the next request re-activates a fresh one that reconstructs.
stopifnot(identical(as.integer(
    system2("sudo", c("systemctl", "stop", "runix-audit.service"))), 0L))
Sys.sleep(1)

## the SAME process closes the intent; the full peer identity still matches
## after the restart (a different process would get actor_mismatch).
st <- s$write_outcome(r, list(operation = "svc.restart",
                              resource = "cups.service", scope = "system",
                              outcome = "ok", effect_issued = TRUE))
stopifnot(isTRUE(st$persisted))

## unavailable never advertises system durability
u <- broker_audit_sink(socket_path = tempfile(fileext = ".sock"))$open_intent(
    list(operation = "x", outcome = "intent"))
stopifnot(!isTRUE(u$persisted), identical(u$error, "runix_broker_unavailable"),
          is.na(u$audit_scope))

## an UNTRUSTED (non-root) broker cannot be mistaken for the system broker: run
## one as this unprivileged user; the root-pinned sink refuses its peer.
td <- tempfile("rab-unpriv-")
dir.create(td)
usock <- file.path(td, "sock")
upid <- system(sprintf("%s --listen %s --sink %s/a.jsonl >/dev/null 2>&1 & echo $!",
                       shQuote(BIN), shQuote(usock), shQuote(td)), intern = TRUE)
upid <- upid[grepl("^[0-9]+$", upid)][1]
for (i in 1:200) {
    if (file.exists(usock)) break
    Sys.sleep(0.02)
}
ut <- broker_audit_sink(socket_path = usock)$open_intent(
    list(operation = "x", outcome = "intent"))
if (!is.na(upid)) {
    system(paste("kill", upid, "2>/dev/null"))
}
stopifnot(!isTRUE(ut$persisted),
          identical(ut$error, "runix_broker_untrusted_peer"),
          is.na(ut$audit_scope))

writeLines(r$correlation_id, "/tmp/rab-cid.txt")
cat("CLIENT OK: system intent+outcome across a broker restart;",
    "unavailable + untrusted claim no system scope. cid",
    r$correlation_id, "\n")
