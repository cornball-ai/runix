# apt mutation boundary contract

Status: contract (pre-implementation), **revised after review** (2026-08-11,
supersedes the same-day second pass). Covers roadmap gaps 2 and 3 for apt as one
design, because for apt they are the same design: authorization, the global dpkg
lock, transaction identity, and concurrency all meet at the moment a package
operation is issued. systemd and apt stay separate *implementations* behind the
shared effect-class policy (`roadmap.md` "Authorization policy: effect class");
this contract is the apt half. It builds on `phase2-mutation-contract.md` (the
mutation discipline) and `durable-audit-contract.md` (how every attempt is
recorded).

**What this revision fixes.** The second pass proposed a `request_id` resume
model and a helper that writes audit; both are corrected here to what is
implementable against the **shipped** audit broker (`runix-audit-broker`
`v0.0.1`):

1. **The unprivileged caller owns the audit.** It opens the intent, invokes an
   effect-only privileged helper, verifies via `pkgstate`, and closes the
   outcome. The helper writes no audit and evaluates no R (else the actor is root
   or the caller's process-bound broker receipt cannot be closed).
2. **v1 defers unattended resume-by-id.** The broker sink is append-only
   *evidence*, never control authority, so `approval_required` is terminal and a
   human re-runs a fresh interactive command that recomputes and confirms the
   plan. "Approve now, apply later unattended" needs a durable approval
   *authority* store and is explicitly deferred.
3. **The broker record schema is a fixed allowlist** (`runix-audit-broker`
   `src/json.c`, `RECORD_SCHEMA`) with no `request_id` or link field. Every field
   the resume model and a written reconciliation record would need is therefore
   specified as an explicit, versioned **broker schema extension** — a
   prerequisite, not an assumption. v1 uses only the shipped schema.
4. **Crash reconciliation cannot close the dead receipt.** After the originating
   process dies its binding/peer identity cannot be reused, so v1 does
   *detection* (by scanning the sink — the broker exposes no query API); the
   linking reconciliation record is deferred to the schema extension.
5. **Scope tightened.** `apt.configure` and hold/unhold gain risk metadata,
   repository/key mutation is deferred to its own hardened contract, and package
   ownership uses rapt's exact predicate across the whole computed transaction.

## Scope and boundary

- **In scope:** the boundary for mutating installed-package state through
  apt/dpkg on the local host: install, remove, purge, upgrade, repository
  and key changes, and list refresh.
- **Out of scope, read side:** querying package state is `pkgstate`, already
  built. apt mutations *use* `pkgstate` to read before/after state.
- **Out of scope, rapt:** `rapt` is the r2u binary R-package install backend
  (the `r-*` allowlist over its own root socket, a deliberate rejection of
  the polkit/PackageKit stack). It is **not** modified, broadened, or
  wrapped by this contract. The general-apt path defined here is separate
  from rapt. Any future unification (the `bsrm` discussion) is a separate
  decision with Dirk and is explicitly not assumed here.
- **Out of scope, backend swap:** whether the effect is issued via the
  `apt-get`/`dpkg` CLI bridge or a native libapt binding (RcppAPT) is the
  Phase-4 backend question. This contract fixes the *boundary* (authz, lock,
  identity, audit); the CLI bridge is the initial backend under the usual
  discipline (`LC_ALL=C`, verify postconditions, injectable runner).

## Risk and authorization metadata per operation

Applying the roadmap's authorization-and-risk policy to apt: each operation
carries explicit metadata, and the **fleet policy** reads it to decide
go/no-go, rather than a fixed "install vs update" verb category (an upgrade
can be as disruptive as an install). `preview_available` is `TRUE` for all of
these via apt's simulate. `approval_required` below is the **default**; the
fleet policy may raise or lower it per operation and per host role.

**`requires_authorization` and `approval_required` are orthogonal axes; do not
collapse them.**

- `requires_authorization` — does the effect cross an **OS privilege boundary**
  (needs root / a polkit action to run at all)? This is enforced by
  polkit/`pkexec` at the privileged helper, independent of any human.
- `approval_required` — must a **human or fleet controller sign off** before the
  effect runs, over and above OS authorization?

A privileged operation can need no human approval: `apt.update` writes
`/var/lib/apt/lists` as root, so it **requires_authorization** (it is not
unprivileged), yet it defaults to **no** `approval_required` — an agent may run
it autonomously through the privileged helper without a human in the loop.
Collapsing the two would either make routine list refreshes wait on a human, or
falsely mark a privileged effect as needing no OS authorization.

| Operation | reversible | disruptive | requires_authorization | approval_required (default) |
|---|---|---|---|---|
| `apt.install` | partial (remove undoes it) | maybe (config, deps) | yes | yes |
| `apt.remove`, `apt.purge` | maybe (reinstall; purge drops config) | yes | yes | yes |
| `apt.upgrade`, `apt.dist_upgrade` | hard | yes | yes | yes |
| `apt.configure` (repair, `dpkg --configure -a`) | n/a (completes pending config) | maybe (maintainer scripts) | yes | yes |
| `apt.hold` | yes (unhold) | no | yes | no |
| `apt.unhold` | yes (re-hold) | no | yes | yes |
| `apt.update` (list refresh) | n/a (no package change) | no | **yes** | no |

`apt.update` is the one operation an agent runs autonomously by default — but
"autonomous" means "no human approval", **not** "unprivileged": it still runs
through the privileged helper and its polkit action, and is audited like any
other effect. `apt.hold` is likewise privileged-but-unapproved (a defensive pin);
`apt.unhold` removes a pin an operator set, so it defaults to approval. Everything
else defaults to `approval_required` and flows through the approval boundary
below.

**Repository and key mutation (`apt.add_repo`, `apt.import_key`) is deferred to
its own hardened contract** — not v1. Trusting a new archive key is the most
safety-critical apt operation there is, and it shares the exact surface the
A0-release signing work covers: `Signed-By` keyrings under `/etc/apt/keyrings`,
atomic index writes, fingerprint verification, and **no `apt-key`**. It earns a
dedicated contract, not a table row here.

Autonomous security upgrades are a legitimate want (roadmap: agents doing the
boring things), but they already have a first-party home in
`unattended-upgrades` (a systemd timer with its own policy). Runix's
autonomous path for upgrades, if enabled, routes through or mirrors that
mechanism rather than inventing a parallel unattended installer; it is
operator-configured opt-in, never the default, and always audited.

## Authorization: the human gate

Human-gated apt operations require an explicit privilege elevation with a
prompt (matching the operator preference: installs require a real password).
The agent *proposes* the operation and its preview; a human *authorizes* it
at the prompt. Options considered:

1. **Drive PackageKit over D-Bus** and reuse its polkit actions
   (`org.freedesktop.packagekit.package-install`, etc.). Reuses existing
   service-level authorization (the PLAN principle), but leans on a heavy
   stack that is itself a migration target, which is an odd foundation for a
   project replacing that layer.
2. **A dedicated Runix privileged helper**, polkit-gated, invoked via
   `pkexec`, that performs the apt operation as root after the prompt. The
   `pkexec` password prompt is the human gate; the helper is small and
   Python-free; rapt's root-daemon-over-socket design is prior art for the
   privilege separation, without reusing or modifying rapt.
3. **A second long-lived privileged daemon** (rapt-shaped, general apt).
   More moving parts and a persistent attack surface; only worth it if
   per-call `pkexec` latency proves to matter.

**Recommendation:** option 2 for v1, with a strict split of duties. A single
polkit action namespace (e.g. `ai.cornball.runix.apt.manage`) gates a small
Runix apt helper launched with `pkexec`. The helper does **only the effect**: it
validates its arguments, takes the dpkg lock, issues the apt/dpkg transaction,
and returns a structured result. It writes **no audit** and evaluates **no R**.

Everything around the effect is owned by the **unprivileged** R caller, exactly
as the rsystemd path works: the caller opens the durable intent through the
broker (so the audit actor is the real caller via `SO_PEERCRED`, never root),
invokes the helper for the effect, verifies the post-state via `pkgstate`, and
closes the outcome on the same broker interaction. A privileged helper that wrote
the audit itself would either record the actor as root or be unable to close the
caller's process-bound broker receipt at all. Denial at the `pkexec`/polkit gate
raises `runix_unauthorized`; no new resident daemon.

The authorization *descriptor* recorded in the audit (`authorized_via`) names the
polkit action actually checked, exactly as the systemd path records its
`org.freedesktop.systemd1.*` action.

### Interactive vs machine mode: the approval boundary

Option 2's `pkexec` password prompt is the gate for a **human at a terminal**.
It must never be reached by an agent: a `--json` invocation cannot block on an
interactive password. Autonomous operation and a password gate are compatible
only through an explicit approval boundary.

- **Interactive (human, TTY):** the caller computes the preview, `pkexec`
  prompts, the human authenticates, and the effect proceeds inline — one
  operation, one broker interaction (one `correlation_id`, an intent and an
  outcome).
- **Machine mode (`rctl --json`):** a gated operation computes the preview,
  writes a *complete* two-phase pair — an intent and an outcome of
  `approval_required` with `effect_issued = FALSE`, sharing **one**
  `correlation_id` — and returns. It issues no effect and **stops there**.
  `approval_required` is a first-class terminal outcome, distinct from
  `unauthorized` (a denial) and `ok`, surfaced in the envelope (see
  `rctl-json-contract.md`).

**v1 does not resume; a human re-runs.** To apply a machine-mode approval, a
human runs a **fresh interactive command** — a new operation that recomputes the
preview from current state, prompts via `pkexec`, and executes under the human's
own authority. It is not a "resume": it re-reads the world and re-authorizes from
scratch, so it is correct even though the earlier `approval_required` record is
only *evidence*. The two operations — the machine request and the human execution
— are independent, each with its own `correlation_id`; in v1 they correlate in
the audit by operation, resource, actor, and time window, enough to review that a
request was later carried out.

**Why not resume-by-id in v1.** Handing back an id and later executing against it
unattended would treat the audit record as *control authority*. It is not: the
durable sink is append-only **evidence** (`durable-audit-contract.md`), and the
broker mints and owns the `correlation_id` per interaction (`SO_PEERCRED`,
per-connection framing), so a later, different process cannot reuse the request's
receipt or append to it. A sound "approve now, apply later **unattended**" needs
two things this contract deliberately **defers**:

- a **durable request/approval authority** — a store, separate from the evidence
  sink, recording "request R was approved by principal P at time T", consultable
  and revocable by an unattended executor; and
- a **broker schema extension** so the request identity and the plan it pins are
  first-class record fields the execution can carry and reconcile against (see
  "Broker schema dependency").

Until both exist, machine mode stops at `approval_required` and a human applies
it. When the request identity *is* modelled, the execution must still re-check
everything before acting — host/actor binding, authorization *again*, the
operation parameters and a preview-plan hash, a TTL, and current pre-state — and
refuse (`runix_stale_request` for drift/expiry/mismatch, `runix_unauthorized`
for authz) rather than run a stale plan because someone holds an id. The id is
never a bearer token. That machinery is specified **with** the deferred store,
not built into v1.

## Broker schema dependency

The durable audit is written through `runix-audit-broker`, whose record schema
is a **fixed allowlist** (`src/json.c`, `RECORD_SCHEMA`): `operation`, `outcome`,
`resource`, `scope`, `audit_scope`, `authorized_via`, `completion_method`,
`job_result`, `observed_reason`, `preview`, `effect_issued`, `changed`,
`state_changed`, `observed_failed`, `elapsed`, `observed`. Broker-owned fields
(`correlation_id`, `actor`, `phase`, `host`, `pid`, `time`, `schema_version`) are
stamped by the broker and rejected if a client sends them. Any field **not** in
the allowlist is rejected — so a client cannot smuggle a `request_id` or a
cross-record link through today's broker.

- **v1 uses only the shipped schema.** Everything above (ungated ops, terminal
  `approval_required`, gated interactive execution, broken-state detection) fits
  the existing fields. No broker change is required to ship v1.
- **The deferred features name their schema extension.** Unattended resume-by-id
  and a written reconciliation record both need fields the broker does not have.
  Rather than overload `observed`, the extension is explicit: add `request_id`
  (string) and `reconciles` (string — the abandoned `correlation_id`) to
  `RECORD_SCHEMA`, bump the broker `schema_version`, and add broker conformance
  fixtures (the new fields validate; a record without them still validates; older
  clients are unaffected). Those features are gated on this extension landing and
  being re-pinned, exactly as the R stack re-pins `janssonr` after a change.

## Global lock and concurrency

There is one system-wide apt/dpkg mutation lock (the dpkg frontend lock).
Only one package transaction runs at a time on a host, and Runix is not its
only contender: a human at a terminal, `unattended-upgrades`, PackageKit, or
another Runix agent may hold it.

- **Never bypass the frontend lock.** Runix acquires it through the normal
  apt path, never by deleting or ignoring lock files.
- **Bounded wait.** apt (>= 2.0, present on Ubuntu 24.04) supports
  `-o DPkg::Lock::Timeout=<seconds>`; Runix passes a caller-set timeout and
  raises typed `runix_apt_locked` if the lock cannot be taken in the window.
  `timeout = 0` is fail-fast for agents that must not queue; a positive
  value queues politely behind whoever holds it.
- **`runix_apt_locked` is retryable** and is registered in the shared runix
  retryability registry (the apt package's `.onLoad`, the same pattern
  `pkgstate` uses for `pkgstate_cache_race`), so `rctl` marks it retryable
  via `runix::is_retryable()` with no hardcoded string.
- **Runix-local coordination (optional).** Runix may take its own advisory
  lock before attempting, so two Runix agents on one host produce a clean
  `runix_apt_locked` and ordered queueing rather than both blocking opaquely
  on dpkg. The dpkg frontend lock remains the source of truth; the local
  lock is only for cleaner diagnostics and ordering.

**Asymmetry with systemd, stated explicitly.** systemd serializes its own
jobs via PID 1 (two `systemctl restart`s queue), so the Phase 2 systemd path
needs no lock design of its own. apt has no such server; the dpkg lock *is*
the serialization, and handling contention is the apt path's job. This is
why the two subsystems are separate implementations behind one policy.

## Transaction identity

Two identities exist in v1; a third arrives with the deferred schema extension.

- **`correlation_id` — one broker interaction (v1).** Broker-minted and
  broker-owned per connection (`SO_PEERCRED` framing), it identifies a single
  intent/outcome pair in a single process. Every operation has exactly one —
  including a machine-mode gated request (its intent and its `approval_required`
  outcome share it) and, separately, the human execution that later applies it.
  Never reused across processes, never carries authority.
- **The native dpkg transaction.** apt/dpkg keep their own logs
  (`/var/log/apt/history.log`, `/var/log/dpkg.log`) with their own transaction
  boundaries. The execution tags its invocation (a recorded `Commandline`/marker
  plus the start/end window) so the Runix operation reconciles to the native log
  entry after the fact: "which dpkg transaction did Runix cause" is answerable,
  not inferred. In v1 this runs `correlation_id → native dpkg transaction`, and
  the two evidence records (machine request, human execution) correlate by
  operation/resource/actor/window.
- **`request_id` — the durable operation request (deferred).** A stable identity
  that spans the approval boundary and links a request to its later execution as
  a first-class record field. It requires the broker schema extension above and,
  for unattended use, the durable approval store — it is **not** in v1. Until it
  lands, cross-operation correlation is by evidence attributes, not a stored id.

## Package ownership

Not every installed package is Runix's to mutate. The general-apt helper owns a
bounded domain and refuses to step outside it, so two managers never fight over
the same dpkg state and a mutation can never brick the host.

- **rapt's `r-*` domain is off-limits, checked across the whole transaction.**
  `rapt` owns the r2u R-package packages, identified by its exact predicate
  (`^r-[a-z]+-[a-z0-9.]+$`, `rapt` `r-pkg/R/manager.R`). The general-apt helper
  **refuses** any operation that would install, remove, or upgrade a package rapt
  owns; those go through rapt. Two rules make this sound: (a) use rapt's *exact*
  predicate — shared from rapt, not re-copied, so the two never drift — and (b)
  apply it to **every package in the computed transaction**, not only the
  requested target, since apt pulls dependencies: an operation on a non-`r-`
  package that would drag in or remove an `r-` package still crosses the
  boundary. A cross-domain transaction is refused typed
  (`runix_package_not_owned`), never silently retargeted or partially applied.
- **Holds are honored.** A package under `apt-mark hold` (or pinned to refuse the
  change) is not overridden; the blocked mutation is surfaced with the hold in
  `observed`, never silently unheld. Clearing a hold is its own explicit, audited
  operation.
- **Essential / protected packages are refused.** Removing an `Essential: yes`
  or `Priority: required` package, or apt's protected set, can render a host
  unbootable or unmanageable. The helper refuses (`runix_protected_package`)
  rather than relying on apt's last-ditch interactive prompt, which an agent
  never sees. An operator who means it uses the native tool deliberately; Runix
  does not ship that foot-gun by default.
- **Foreign-managed packages are surfaced, not clobbered.** Where Runix can tell
  a package is managed by another mechanism, that fact goes in the preview for
  the policy to weigh, rather than the helper assuming ownership.

Ownership is checked whenever a plan is computed — at preview and again in the
fresh interactive execution's own recompute — so a package that became
owned/held/protected in between is caught, not acted on.

## Preview, idempotence, postconditions

Consistent with the Phase 2 mutation discipline:

- **Preview** uses apt's simulate (`apt-get -s` / `--simulate`): it computes
  and returns the plan (packages added/removed/held, download size) and
  issues no effect. A preview is audited with `effect_issued = FALSE`.
- **Idempotence.** Installing a package already at the candidate version, or
  removing an absent package, is a `no_op`: no effect issued, `changed =
  FALSE`. `changed` (functional effect) and `state_changed` (raw observed
  transition) follow the Phase 2 definitions.
- **Postcondition verification.** After issuing an effect, Runix reads back
  the real state via `pkgstate` and reports the *observed* result, not the
  intent. The result is a `runix_result` (core object) subclassed
  `apt_result`, with `before`/`after` drawn from `pkgstate`.

## Partial failure and recovery

The apt-specific hazard with no systemd analogue: an interrupted or failing
dpkg run can leave packages half-configured, i.e. the system in a broken
state that later apt operations refuse to proceed past.

- After any effect, Runix checks for a broken/half-configured state (dpkg
  status audit) before reporting success.
- A broken state is surfaced as typed `runix_dpkg_broken` with the standard
  recovery hint (`dpkg --configure -a`) in the condition data; Runix does
  **not** silently auto-repair, and never reports `outcome = "ok"` over a
  broken dpkg database.
- The durable-audit outcome record captures the broken state in `observed`,
  so the failure is on the record, not just in the moment.

**Interrupted mid-transaction (the crash case).** If the execution process dies
between issuing the effect and writing its outcome (SIGKILL, OOM, power loss —
the A1 "hard death" hazard, now over a package transaction), the durable record
is left with an execution **intent but no outcome** (its `correlation_id` open),
while dpkg may be part-applied. Detectable, not self-healing:

- **Detection (v1).** Open intents are found by **scanning the durable sink**
  (root-readable JSONL) for an intent with no matching outcome for its
  `correlation_id` — the broker exposes **no query API**, so discovery is a read
  of the evidence, not a broker call. As in A1 gate 6, Runix *detects* the open
  intent and surfaces it as unreconciled; it does not silently close it.
- **The dead receipt cannot be closed.** The originating process is gone; its
  broker binding and peer identity cannot be reused, so its `correlation_id` can
  never receive an outcome. A durable reconciliation cannot append to it — it
  must be a **new** broker interaction that *references* the abandoned
  `correlation_id`. That reference is not a field the shipped broker accepts (see
  "Broker schema dependency"), so **writing the reconciliation record is deferred
  to the schema extension** (the `reconciles` field). Until then reconciliation is detection
  plus out-of-band operator resolution against dpkg ground truth (the native
  transaction log window + current dpkg status), which decides what actually
  happened; the effect is never assumed from the mere existence of an intent.
- **Repair is an explicit, gated operation**, never automatic. `apt.configure`
  (`dpkg --configure -a` through the same privileged, audited boundary) is a
  first-class mutation with its own `correlation_id`, authorization, and audit —
  not a cleanup Runix performs on your behalf. A broken database is surfaced and
  left for a deliberate, authorized repair.

## Typed errors and retryability

- `runix_unauthorized` — polkit/pkexec denied (terminal).
- `runix_apt_locked` — lock not acquired within the timeout (**retryable**).
- `runix_operation_failed` — apt/dpkg returned nonzero for a definite
  failure (terminal; carries the tool's diagnostic).
- `runix_dpkg_broken` — post-effect broken/half-configured state (terminal;
  carries the recovery hint; repaired only via the gated `apt.configure`).
- `runix_package_not_owned` — the target is outside the general-apt helper's
  domain (e.g. rapt's `r-*` packages); terminal, use the owning backend.
- `runix_protected_package` — refused removal of an `Essential`/`required`/
  protected package; terminal.
- `runix_stale_request` — **(deferred, ships with resume-by-id)** a resumed
  execution failed revalidation (expiry, pre-state drift, or
  parameter/preview-hash mismatch); terminal, re-preview required. Not a v1
  error: v1 has no resume, so a fresh interactive execution simply recomputes.
  Authorization failures are always `runix_unauthorized`.

All inherit `runix_error` via `runix::runix_abort()`; all mutation attempts,
including every one of these, emit durable audit records per the two-phase
rule (no silent error paths).

## Audit integration

apt mutations use the durable-audit two-phase write, owned by the **unprivileged
caller** (not the helper):

- **Intent** opened by the unprivileged R caller through the broker *before*
  invoking the helper — so before any lock is taken or effect issued. If it
  cannot persist, abort before touching the system. The actor is the caller's
  kernel identity (`SO_PEERCRED`), never root.
- **Effect** is the helper's only job (it takes the dpkg lock and issues the
  transaction); the helper writes no audit.
- **Outcome** closed by the caller on the same broker interaction, with the real
  `effect_issued`, the `observed` post-state read back from `pkgstate`,
  `outcome`, `elapsed`, and the same `correlation_id`. `audit_persisted` is
  reported honestly on the result.

## Where this lives

The apt mutation surface is a new subsystem package (provisionally `pkgops`;
sibling to `rsystemd`, consumer of `pkgstate` and the `runix` core), not part of
`pkgstate` (which stays **read-only**) and not part of `rapt`. It Imports the
`runix` core for
conditions, the runner, the result shell, retryability registration, and the
audit emitter, exactly as `rsystemd` does. `rctl` gains `packages.install`,
`packages.remove`, `packages.upgrade`, etc. as mutating operations behind the
same envelope, with the human-gated ones marked so an agent knows they will
prompt.

## Conformance tests

Against an injectable runner, lock, and audit sink:

1. A human-gated op with authorization denied raises `runix_unauthorized`,
   issues no effect, and still writes an intent audit record.
2. Lock held past the timeout raises `runix_apt_locked`, which
   `runix::is_retryable()` reports retryable.
3. Installing an already-current package is a `no_op`: no effect issued,
   `changed = FALSE`, audited.
4. Preview returns a plan, issues no effect, and audits with
   `effect_issued = FALSE`.
5. A simulated interrupted transaction is detected and surfaced as
   `runix_dpkg_broken`, never as `ok`; the broken state is in `observed`.
6. Postcondition verification reads back through `pkgstate` and reports the
   observed state, not the requested one.
7. Two concurrent Runix apt attempts do not both proceed; the loser gets
   `runix_apt_locked`, and both attempts are attributable by
   `correlation_id`.
8. The intent/outcome audit pair shares one `correlation_id`; an
   un-persistable intent aborts before any effect.
9. Machine-mode approval is terminal: a gated op in `--json` returns
   `approval_required`, writes a complete intent + `approval_required` outcome
   sharing **one** `correlation_id` with `effect_issued = FALSE`, and issues no
   effect. No id is handed out for resume.
10. Axis separation: `apt.update` is `requires_authorization = TRUE` (it runs
    through the privileged helper and its polkit action) yet
    `approval_required = FALSE`; a package-changing op defaults
    `approval_required = TRUE`. The two flags move independently.
11. Independent operations, no reused receipt: a machine-mode request and a later
    human execution are **separate** operations with **different**
    `correlation_id`s; in v1 neither carries a `request_id`, and they correlate
    only by operation/resource/actor/window. Broker-level: a record carrying a
    `request_id` or `reconciles` field is rejected by the shipped `RECORD_SCHEMA`,
    so v1 provably cannot rely on them — the deferred features are gated on the
    schema extension.
12. Interrupted transaction: an execution whose outcome is never written leaves
    an open intent with no matching outcome for its `correlation_id`, found by
    **scanning the sink** (the broker has no query API) and surfaced as
    unreconciled; the dead `correlation_id` receives no outcome, and no
    reconciliation record is written against the shipped broker. Repair is only
    via the gated `apt.configure`.
13. Package ownership over the whole transaction: an operation whose **computed
    plan** touches any package matching rapt's exact predicate
    (`^r-[a-z]+-[a-z0-9.]+$`) — target or pulled dependency — is refused
    `runix_package_not_owned` and not partially applied; removal of an
    `Essential`/protected package is refused `runix_protected_package`; a held
    package's mutation is refused with the hold in `observed`. Each refusal still
    writes its intent record.

## Verification ladder

Fixtures cannot reproduce the parts of apt that make it dangerous — the dpkg
frontend lock under real contention, maintainer scripts, a genuinely interrupted
transaction, conffile prompts, or a partially-configured database. The
conformance tests above (fixture level, against an injectable runner/lock/sink)
are necessary but not sufficient. The full ladder, and the order it is built in:

    contract  ->  helper/API implementation  ->  fixture tests
              ->  minimal destructive disposable-VM gate

The final stage is a **minimal** destructive acceptance on a disposable VM (the
A1 canary harness, `deploy/canary/`), **never the troy-g5 host**: a harmless
local test package and repository exercise a real install/remove/upgrade, a real
held/protected refusal, real lock contention, and a real interrupted transaction
with its reconciliation — the behaviours fixtures can only stub. It is the apt
arc's last gate, not a feature of its own.
