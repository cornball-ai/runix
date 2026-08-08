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

## Why Runix, not the Python tools

The Python admin layer (apt, aptdaemon, software-properties, netplan,
cloud-init, ...) is a set of bespoke tools that emit human-readable text,
each with its own error style, idempotence story, and D-Bus quirks. Runix
does not replace what they *do* — apt and systemd still do the work — it
replaces the *interface contract*: one typed surface over all of them, with
a shared result object, condition taxonomy, and preview/audit/authorization
discipline.

The deeper bet: system administration is a data problem that got flattened
into text because the tools were built for humans at a terminal. Package
state, unit state, upgrade candidates, journal entries are tables and time
series wearing text costumes. R is a query engine for tables, so an R admin
layer returns `data.frame`s you can filter, join, and `rbind()` across a
fleet instead of re-parsing stdout per host. Match the tool to the true
shape of the data.

This payoff is conditional. For one machine with a human at the keyboard,
the native tools are fine and Runix is ceremony. The value shows up at fleet
scale, under agent operation, and where auditability matters — the intended
workload, not a single desktop.

r2u/rapt is the install *transport* that carries these packages to the fleet
(fast, Python-free), not the foundation. The foundation is the
typed-API-over-native-interfaces spine (the `runix` common core).

## Authorization policy: effect class

Authorization is drawn by **effect class**, not by tool or verb:

- **Human-gated** — hard-to-reverse, trust-boundary-crossing operations
  (package install/remove, repository add, key import). These require an
  explicit human gate (sudo + password / polkit prompt). An agent proposes;
  a human authorizes.
- **Agent-autonomous** — routine operations inside an already-trusted set
  (service restart/enable, unattended security updates, cache refresh).
  These run without a prompt but stay previewable and audited.

Runix's job is to **surface which class an operation is in** so the caller
(agent or human) knows when to stop and ask, via the planned-effect and
authorization fields already on `runix_result`. polkit enforces the
privileged gate at the D-Bus boundary; Runix makes the class legible above
it. Gap 2 (apt mutation boundary) is where this policy becomes a concrete
contract for the install/remove path.

## Built so far

- **Phase 0** — Ubuntu Python-admin inventory (`ubuntu-python-admin-inventory.md`).
- **Phase 1** — read-only introspection: `pkgstate` (dpkg/apt queries),
  `rsystemd` (units, journal, timers, state), `rctl --json` (versioned
  envelope, typed errors), acceptance vs `ubuntu-security-status`.
- **Phase 2 (systemd slice)** — `rsystemd` mutations (start/stop/restart/
  enable/disable) with preview, idempotence, job correlation, timeout/
  cancellation, service-level authz, per-outcome audit; surfaced through
  `rctl services.*`.
- **`runix` common core** (`runix-core.md`) — extracted and adopted:
  conditions taxonomy, retryability registry, injectable runner, neutral
  result shell. pkgstate/rsystemd/rctl all Import it and deleted their
  duplicated copies; rctl classifies retryability via the shared registry
  (no hardcoded class table).

## Open gaps (codex review 2026-08-07 + additions)

Priority: **[U]** urgent, **[N]** next, **[L]** later.

1. **[U] Durable audit sink.** Mutation results carry audit records, but
   there is no durable, queryable sink (append-only, rotation, tamper
   expectations). **Addition:** mutation *errors* (timeout/cancel/failed/
   unauthorized) currently carry `observed` state but emit **no** audit
   record — only successful results do. The contract says audit every
   effect including failures; fix this when building the sink. Prior art:
   corteza's JSONL diagnostics, viento's fsync'd WAL.
   **Contract written:** `durable-audit-contract.md` (two-phase
   intent/outcome, the four separated facts, fail-closed before any
   un-recorded effect, honest `audit_persisted`); implementation pending.
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
   contract (done).
2. `runix` common-core extraction — **done**: core package plus
   pkgstate/rsystemd/rctl adoption merged.
3. **Durable audit** contract pass (covers gap 1, including error-path
   audit) — **contract written** (`durable-audit-contract.md`);
   implementation next, foundational for trustworthy mutations.
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
