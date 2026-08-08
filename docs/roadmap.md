# Runix roadmap and known gaps

Living document. Started 2026-08-07.

## Mission (one sentence)

> Runix is an R-native, agent-drivable Linux administration layer intended
> to replace suitable first-party Python administrative layers while
> exposing cleaner, typed APIs over the existing native system interfaces.

It is **not** a line-by-line port of Python packages, a replacement for
Python itself, or a recreation of every GUI/daemon. Python admin tools are
the migration targets and prior art; apt, systemd, D-Bus, NetworkManager,
and dpkg remain the underlying machinery. (Refines PLAN.md's Working Thesis.)

## Built so far

- **Phase 0** — Ubuntu Python-admin inventory (`ubuntu-python-admin-inventory.md`).
- **Phase 1** — read-only introspection: `pkgstate` (dpkg/apt queries),
  `rsystemd` (units, journal, timers, state), `rctl --json` (versioned
  envelope, typed errors), acceptance vs `ubuntu-security-status`.
- **Phase 2 (systemd slice)** — `rsystemd` mutations (start/stop/restart/
  enable/disable) with preview, idempotence, job correlation, timeout/
  cancellation, service-level authz, per-outcome audit; surfaced through
  `rctl services.*`.
- In flight: `runix` common-core extraction (`runix-core.md`).

## Open gaps (codex review 2026-08-07 + additions)

Priority: **[U]** urgent, **[N]** next, **[L]** later.

1. **[U] Durable audit sink.** Mutation results carry audit records, but
   there is no durable, queryable sink (append-only, rotation, tamper
   expectations). **Addition:** mutation *errors* (timeout/cancel/failed/
   unauthorized) currently carry `observed` state but emit **no** audit
   record — only successful results do. The contract says audit every
   effect including failures; fix this when building the sink. Prior art:
   corteza's JSONL diagnostics, viento's fsync'd WAL.
2. **[U] General apt authorization.** rapt authorizes only r2u-allowlisted
   (`r-*`) installs; `apt_install("curl")` needs a separate security
   design (polkit / PackageKit / a broadened or second daemon path). This
   is the blocker for the Phase 2 apt slice. **Addition:** this converges
   with gap 4 for apt — the dpkg global lock means apt-mutation
   authorization and apt-mutation concurrency are one "apt mutation
   boundary" design, not two.
3. **[U] Mutation concurrency and locking.** Two agents mutating at once
   need explicit conflict/lock behavior and operation identity.
   **Note:** systemd already serializes its own jobs via PID 1 (two
   `systemctl restart`s queue), and our InvocationID gives operation
   identity — so the acute gap is apt (global dpkg lock), i.e. gap 2's
   boundary. Document systemd's inherited serialization explicitly; design
   apt's.
4. **[N] CLI-bridge retirement plan.** Define the trigger for moving a
   subsystem from CLI parsing to native bindings (sd-bus / libapt via
   RcppAPT) and how backend behavior stays compatible. The injectable
   runner + fixtures already give the swap seam; formalize when/how and the
   compatibility bar (same fixtures pass against the native backend).
5. **[L] Deployment matrix.** Test supported Ubuntu/R versions, missing
   systemd, user sessions, permissions, upgrades, and `.deb` stack
   rollback. We have single-image container validation; expand it.
6. **[L] Per-target replacement strategy.** For each Phase 4 Python target:
   coexistence, integration/compat tests against the original, `.deb`
   packaging, and deprecation path — not just a rewritten implementation.

## Immediate sequence

1. Merge `rsystemd` authz-audit fix (#5) and the `runix` common-core
   contract (merged).
2. `runix` common-core extraction (its own PR set).
3. **Durable audit** contract pass (covers gap 1, including error-path
   audit) — foundational for trustworthy mutations.
4. **apt mutation boundary** contract pass (gaps 2 + 3 for apt together):
   authorization + concurrency/locking + operation identity, behind rapt or
   a dedicated privileged path.
5. apt mutation implementation; then gaps 4–6 incrementally.

## Deferred decisions

- **R version floor** — none declared yet in any package. Decide only if
  production code needs a base primitive (e.g. base `%||%`, R ≥ 4.4.0),
  after checking Ubuntu/r2u deployment support. Not imposed to delete test
  helpers.
- **rapt → bsrm rename** — separate project, pending Dirk.
- **Native apt-read backend** — apt reads live in `pkgstate` (the unified
  query package); the CLI bridge is the current backend, and the native
  libapt backend should reuse/coordinate with RcppAPT, decided with Dirk.
