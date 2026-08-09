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
workload, not a single desktop. Usefulness is a claim to validate against
concrete fleet workflows (see "Validation"), not to assume from the
abstraction: an agent already drives `systemctl` and `apt` well, so Runix
earns its place only where it makes a real workflow materially safer.

A second, honest value is blast-radius control. Cutting-edge Python work can
wreck a host on a fat-fingered command or a forgotten venv, and an agent
running arbitrary shell or Python has the whole machine in scope. The safety
does **not** come from R: a badly designed mutation API in R is just as
destructive. It comes from the boundary every mutation passes through:

    typed operation -> preview -> explicit authorization
    -> durable intent audit -> narrowly-scoped effect
    -> observed post-state -> outcome audit

Shipping that boundary as stable `.deb` packages, rather than assembling it
in a user's virtualenv, is part of the safety story. Runix must never claim R
is inherently safe; the boundary is what is safe.

r2u/rapt is the install *transport* that carries these packages to the fleet
(fast, Python-free), not the foundation. The foundation is the
typed-API-over-native-interfaces spine (the `runix` common core).

## Authorization and risk policy

Authorization is **not** a binary "human vs autonomous" split by tool. That
split is wrong: an update can be as disruptive as an install (a restart
causes an outage, a security upgrade pulls cross-cutting changes). Instead
each operation carries explicit **risk and authorization metadata**, and a
separate **fleet policy** reads it to decide whether a given agent may
proceed:

- `reversible` — can this be cleanly undone?
- `disruptive` — can it cause an outage (restart, removal)?
- `requires_authorization` — does it cross a privilege/trust boundary?
- `preview_available` — can the effect be simulated first?
- `approval_required` — must a human or controller sign off before it runs?

polkit enforces *authorization* at the privileged boundary; it does not
decide *operational risk*. The go/no-go decision belongs to the fleet policy
reading this metadata, not to a hardcoded verb category. Runix's job is to
make the metadata legible on the result and the envelope; the policy engine
is a downstream consumer, not part of the subsystem packages.

**The approval boundary (machine mode never blocks on a password).** An
autonomous agent and a sudo/password gate are compatible only through an
explicit, asynchronous approval boundary. In machine mode (`rctl --json`) a
gated operation must never wait on an interactive prompt: it returns
`approval_required` carrying the operation identity (the audit
`correlation_id`) and its preview, and stops. A human or fleet controller
authorizes out of band, and the operation is resumed by identity. The
interactive `pkexec`/polkit password prompt is for a human at a terminal,
never for an agent in `--json` mode. The durable **intent** record (written
before anything is issued) is what makes "approve later, resume by id"
sound: the attempt is on disk before it can proceed. The `correlation_id` is
an identifier, not a bearer token: resume revalidates authorization,
host/actor binding, parameters/preview hash, expiry, and pre-state, so a
stale preview is never executed just because someone holds its id. Gap 2 (apt
mutation boundary) is where this becomes a concrete contract for the install
path.

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
   corteza's JSONL diagnostics; fsync'd write-ahead logging in internal
   cornball tooling.
   **Contract written:** `durable-audit-contract.md` (two-phase
   intent/outcome, the four separated facts, fail-closed before any
   un-recorded effect, honest `audit_persisted`).
   **Sink implemented** in the `runix` core (`file_audit_sink`,
   `memory_audit_sink`, `audit_two_phase`, `encode_json_line`): append-only
   JSONL, advisory lock with stale recovery, fsync, rotation, perms/symlink
   guards, fallback, honest `persisted`, plus reboot/PID-reuse-safe locking and
   parent-dir fsync. **Authority matrix ratified (v1):** the weaker
   caller-owned sink as an **explicit capability** — `audit_scope = "caller"`,
   `system_durable_audit = FALSE` advertised via `rctl capabilities`, fleet
   policy may refuse mutations lacking system-durable audit, never claimed as
   the strong guarantee. **Autonomous fleet-wide system mutation stays
   disabled by policy until the broker (gap 7) exists.** Remaining: wire the
   sink into the rsystemd (then apt) mutation paths with caller-owned audit +
   the capability, so effects and error paths emit records.
2. **[U] General apt authorization.** rapt authorizes only r2u-allowlisted
   (`r-*`) installs; `apt_install("curl")` needs a separate security
   design (polkit / PackageKit / a broadened or second daemon path). This
   is the blocker for the Phase 2 apt slice. **Addition:** this converges
   with gap 4 for apt — the dpkg global lock means apt-mutation
   authorization and apt-mutation concurrency are one "apt mutation
   boundary" design, not two.
   **Contract written:** `apt-mutation-boundary-contract.md` (pkexec/polkit
   human gate, dpkg frontend lock with bounded wait, `correlation_id`,
   partial-failure recovery); combines this with gap 3. rapt untouched.
3. **[U] Mutation concurrency and locking.** Two agents mutating at once
   need explicit conflict/lock behavior and operation identity.
   **Note:** systemd already serializes its own jobs via PID 1 (two
   `systemctl restart`s queue), and our InvocationID gives operation
   identity — so the acute gap is apt (global dpkg lock), i.e. gap 2's
   boundary. Document systemd's inherited serialization explicitly; design
   apt's. **Contract written:** folded into
   `apt-mutation-boundary-contract.md` (the dpkg-lock and concurrency
   half); systemd's PID-1 serialization documented there as the asymmetry.
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
7. **[N] Fleet control-plane primitives.** `rctl --json` is the data model;
   turning it into a fleet control plane needs more: stable host identity,
   schema negotiation and version reporting, capability reporting, durable
   operation IDs (the audit `correlation_id`, reused), a remote transport,
   and drift/state comparison across hosts. Downstream of the current
   foundation, but this is what makes the typed data model an operable
   control plane rather than a nicer local CLI. The `approval_required`
   resume lifecycle and durable audit (gap 1) are prerequisites.
8. **[N] Audit broker (system-durable audit for unprivileged callers).** The
   strong resolution of the authority matrix and the gate for autonomous
   fleet-wide system mutation: a small, single-purpose, credential-aware
   (`SO_PEERCRED`), append-only privileged writer that appends a caller's
   validated record to the system sink. Explicitly **not** the apt `pkexec`
   helper (different privilege surface; a prompt would break autonomous
   operation). **Contract written:** `audit-broker-contract.md` (socket
   activation, broker-owned path, `SO_PEERCRED` identity, broker-minted intent
   ids, outcome bound to actor/intent, strict framing/schema/size, rate
   limits, hardened atomic append+fsync, crash-gap preservation, no mutation
   authority). journald evaluated: qualifies only as a **weaker** broker
   (submission is not durable persistence; `SyncIntervalSec`, retention, and
   rate limiting weaken the `audit_persisted` invariant), so it cannot back
   `system_durable_audit = TRUE`. The strong broker's presence flips
   `system_durable_audit` to `true`. **Wire protocol pinned** (versioned
   length-prefixed frames with a hard max, audited C JSON parser,
   `open_intent`/`write_outcome` only, `SO_PEERCRED` over payload, opaque
   non-authorizing receipt binding, typed errors, disconnect never erases a
   durable intent) plus broker I/O (`O_APPEND`/`O_NOFOLLOW`, advisory lock,
   complete-write loops, `fdatasync`, parent-dir fsync) and sandboxed systemd
   socket/service units. **Build sequence:** (2) C broker, (3) R AF_UNIX
   client adapter (a broker-backed sink), (4) protocol/abuse tests, (5)
   rsystemd re-integration + live unprivileged gate before advertising the
   strong capability. The receipt-based sink interface (step 1) is done.
   **Settled decisions:** AF_UNIX + socket activation for v1 (D-Bus deferred
   to when `rdbus` exists); **Jansson** for the broker parser (apt-serviced,
   native `JSON_REJECT_DUPLICATES`, which json-c cannot do); no `janssonr` R
   package (the C broker and R stack meet at the wire schema, not a shared
   library; `yyjsonr` stays on the R side). Repo:
   `cornball-ai/runix-audit-broker`; the json-c-independent core (framing,
   hardened sink, peer creds, getrandom ids/bindings) is implemented and
   passes under ASan/UBSan (draft PR #1). Build binary/tests pending
   `libjansson-dev`.

## Immediate sequence

1. Merge `rsystemd` authz-audit fix (#5) and the `runix` common-core
   contract (done).
2. `runix` common-core extraction — **done**: core package plus
   pkgstate/rsystemd/rctl adoption merged.
3. **Durable audit** (covers gap 1, including error-path audit) — **contract
   written, core sink implemented and hardened, authority matrix ratified**
   (`durable-audit-contract.md`; sink, two-phase driver, JSON encoder in the
   `runix` core with failure/crash-path tests). **Next: rsystemd integration
   with caller-owned audit** — route the mutation verbs through
   `audit_two_phase` (intent before the effect, outcome after), write to the
   caller-owned sink, set `audit_scope`, advertise `system_durable_audit`, and
   keep autonomous fleet system mutation policy-disabled until the broker
   (gap 8). Foundational for trustworthy mutations.
4. **apt mutation boundary** contract pass (gaps 2 + 3 for apt together):
   authorization + concurrency/locking + operation identity — **contract
   written** (`apt-mutation-boundary-contract.md`), a dedicated
   pkexec/polkit-gated helper, rapt left as-is.
5. apt mutation implementation; then gaps 4–6 incrementally.

## Validation: the workflow that must be materially better

Usefulness is conditional and gets validated against a concrete fleet
workflow, not assumed from the abstraction. The acceptance test: is this
workflow materially safer and simpler through Runix than through
Python/Ansible plus the native tools?

    collect package + service + journal state across the fleet
    -> join and identify risky upgrades (in R)
    -> generate a preview
    -> obtain approval (the approval boundary)
    -> apply in batches
    -> verify observed post-state
    -> resume the failures by operation id
    -> produce a durable audit report

If Runix makes that pipeline meaningfully better, it has a compelling niche.
If it merely wraps commands in R and returns data frames, existing agents
already do the job. The differentiators to prove out: one stable schema
across packages/services/logs/hosts; mutations that return verified
post-state instead of trusting exit codes; consistent preview/authorization/
retry/cancellation/audit; fleet-wide joins and policy in R; and resumable
operation identities with partial-failure handling.

## Canary environment: troy-g5

Runix and Viento get validated on **troy-g5** (a GPU host also running Viento
and GPU workloads), not on the primary workstation. GPU hosts are unusually
sensitive to kernel, NVIDIA, initramfs, and networking changes, so the canary
runs at two levels:

1. **A disposable VM on troy-g5** for destructive testing: `.deb` install,
   socket activation, sandbox directives, broker restarts, malformed clients,
   and eventually apt mutations. Containers are fine for builds/fuzzing but do
   not faithfully reproduce host systemd, D-Bus, polkit, or peer credentials,
   so the destructive gates need a real VM, not a container.
2. **The troy-g5 host itself** for realistic integration: synthetic
   user/system units, broker operation, `rctl` envelopes, and Viento
   orchestration. **Initially forbidden on the host:** changes to NVIDIA
   packages/services, kernels, boot configuration, networking, SSH, and
   container-runtime services.

The node is labelled a **canary** in Viento, with exact host-identity matching,
an operation allowlist, explicit approval, and before/after audit evidence
required. The first live workflow to prove end to end:

    Viento -> troy-g5 -> capabilities
                       -> preview a synthetic unit restart
                       -> approve
                       -> execute through rctl
                       -> verify InvocationID / post-state
                       -> retrieve the matching intent/outcome audit records

This is where the architecture's value gets demonstrated concretely: Viento
orchestrates and aggregates; Runix supplies the safe, typed, node-local
execution boundary. Autonomous fleet mutation stays disabled until this canary
path — **including recovery from an interrupted operation** — works repeatedly.
The broker's `.deb`/socket-activation/sandbox gates (which need a real systemd
service manager, not a CI container) run here.

## Deferred decisions

- **R version floor** — none declared yet in any package. Decide only if
  production code needs a base primitive (e.g. base `%||%`, R ≥ 4.4.0),
  after checking Ubuntu/r2u deployment support. Not imposed to delete test
  helpers.
- **rapt → bsrm rename** — separate project, pending Dirk.
- **Native apt-read backend** — apt reads live in `pkgstate` (the unified
  query package); the CLI bridge is the current backend, and the native
  libapt backend should reuse/coordinate with RcppAPT, decided with Dirk.
