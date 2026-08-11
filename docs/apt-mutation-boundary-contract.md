# apt mutation boundary contract

Status: contract (pre-implementation), **second pass** (2026-08-11). Covers
roadmap gaps 2 and 3 for apt as one design, because for apt they are the same
design: authorization, the global dpkg lock, transaction identity, and
concurrency all meet at the moment a package operation is issued. systemd and
apt stay separate *implementations* behind the shared effect-class policy
(`roadmap.md` "Authorization policy: effect class"); this contract is the apt
half. It builds on `phase2-mutation-contract.md` (the mutation discipline)
and `durable-audit-contract.md` (how every attempt is recorded).

**Second-pass changes (resolve before code):** (1) `requires_authorization`
and `approval_required` are separated as orthogonal axes — an operation can need
OS authorization but no human approval; (2) the async approval boundary is
re-modelled so it does not reuse a process-bound broker receipt — a durable
`request_id` links a completed approval *request* to a later, newly-identified
*execution*; (3) transaction identity is split into the three levels that
actually exist (durable request, per-attempt broker interaction, native dpkg
transaction); (4) recovery covers an *interrupted* transaction (open intent, no
outcome), not only a broken database; (5) a **package-ownership** boundary
demarcates this helper's domain from rapt's `r-*` domain, holds, and
essential/protected packages.

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
| `apt.add_repo`, `apt.import_key` | yes | no | yes | yes |
| `apt.upgrade`, `apt.dist_upgrade` | hard | yes | yes | yes |
| `apt.update` (list refresh) | n/a (no package change) | no | **yes** | no |

`apt.update` is the one operation an agent runs autonomously by default — but
"autonomous" means "no human approval", **not** "unprivileged": it still runs
through the privileged helper and its polkit action, and is audited like any
other effect. Everything else additionally defaults to `approval_required` and
flows through the approval boundary below.

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

**Recommendation:** option 2 for v1. A single polkit action namespace
(e.g. `ai.cornball.runix.apt.manage`) gates a Runix apt helper launched with
`pkexec`; the helper validates its arguments, takes the lock, issues the
effect, verifies via `pkgstate`, and writes the audit records. Denial raises
`runix_unauthorized`. This keeps the human in the loop for the exact class of
operations the operator wants gated, with no new resident daemon.

The authorization *descriptor* recorded in the audit (`authorized_via`)
names the polkit action actually checked, exactly as the systemd path
records its `org.freedesktop.systemd1.*` action.

### Interactive vs machine mode: the approval boundary

Option 2's `pkexec` password prompt is the gate for a **human at a terminal**.
It must never be reached by an agent: a `--json` invocation cannot block on an
interactive password. Autonomous operation and a password gate are compatible
only through an explicit, asynchronous approval boundary.

- **Interactive (human, TTY):** `pkexec` prompts, the human authenticates,
  the effect proceeds inline — one process, one attempt.
- **Machine mode (`rctl --json`):** a gated operation returns
  `approval_required`, carrying a durable **`request_id`** and the computed
  preview, and stops. It issues no effect. A human or fleet controller
  authorizes out of band, and a *later, separate* invocation executes it,
  linked back by `request_id`.

**Two identities, because the approval spans two processes.** The request that
returns `approval_required` and the execution that later applies the effect are
different attempts, in different processes, at different times. Durable audit is
written through the broker, and the broker **mints and owns the
`correlation_id`** per interaction (`SO_PEERCRED`, per-connection framing) — so
the execution *cannot* reuse the request's `correlation_id`; a process-bound
broker receipt does not carry across the boundary. The join is therefore a
distinct, durable **`request_id`**, minted by Runix at the request, recorded in
the intent as ordinary record content (not a broker-owned field), returned in
`approval_required`, and carried into the execution, which records it as the
link:

- **Approval request** (attempt 1) — a *completed non-effect*. Computes the
  preview; writes a durable intent (`request_id`, actor, host, operation +
  parameters, preview hash, pre-state digest, expiry); emits its outcome record
  as `approval_required` with `effect_issued = FALSE`; returns. Its broker
  interaction has `correlation_id` C₁.
- **Execution** (attempt 2) — a *newly-identified* attempt linked by
  `request_id`. Re-reads the request, revalidates (below), and only then issues
  the effect. Its broker interaction has a different `correlation_id` C₂; its
  records carry `request_id` as the link, so the pair joins to the request
  without ever reusing C₁.

The two record-sets (C₁ = request, C₂ = execution) join by `request_id`. The
`correlation_id` stays what it has always been — the identity of one broker
interaction, never a cross-process handle. `approval_required` is a first-class
terminal outcome, distinct from `unauthorized` (a denial) and `ok`, surfaced in
the envelope (see `rctl-json-contract.md`).

**The `request_id` is an identifier, not a bearer token.** Possessing it must
never be sufficient to execute. Execution is not "run the recorded plan"; it
re-checks everything and only then proceeds. At execution time the helper
revalidates:

- **host and actor binding** — the execution is for the same host and the same
  actor the request recorded; a different principal cannot replay the id;
- **authorization** — the polkit/approval check is run *again* at execution; the
  request record is not proof that authorization happened or still holds. **v1
  re-authorizes at execution:** whoever runs the execution must themselves hold
  authority at that moment (the controller re-issues under its own authority, or
  a human re-prompts). A *durable approval authority* — a store that records
  "request R was approved by principal P at time T" so an unattended runner can
  execute later without re-holding authority — is a heavier, explicitly
  **deferred** alternative, built only if "approve now, apply later fully
  unattended" is actually required. Until then, approval is not a stored grant;
  it is authority exercised at execution against a request that pins the plan.
- **operation parameters and preview hash** — the executed operation must match
  the recorded request exactly (operation, resource, options), bound by a hash
  of the computed plan, so an altered or substituted plan is refused;
- **expiry/staleness** — requests carry a TTL; an execution past it is refused,
  not silently honored;
- **current pre-state** — the system is re-read; if it drifted since the
  preview, the plan is stale and the execution is refused (re-preview required),
  never applied against a changed system.

Any of these failing yields a typed refusal (`runix_unauthorized` for authz
failures, `runix_stale_approval` for expiry/drift/parameter mismatch), audited
like any other outcome. The request audit makes the workflow auditable; it does
not replace re-authorization at execution.

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

Three identities exist at different scopes; keep them distinct.

- **`request_id` — the durable operation request.** Minted by Runix, it names
  the operation the operator authorizes and the unit that spans the async
  approval boundary — for a gated operation the join between the approval request
  and its later execution, and for an ungated operation the logical operation end
  to end. It is ordinary record content, carried on the result and every audit
  record, and never broker-owned.
- **`correlation_id` — one broker interaction.** Broker-minted and broker-owned
  per connection (`SO_PEERCRED` framing), it identifies a single intent/outcome
  pair in a single process. An ungated operation has one; a gated operation has
  two (C₁ for the request, C₂ for the execution). It is never reused across
  processes and never carries authority.
- **The native dpkg transaction.** apt/dpkg keep their own logs
  (`/var/log/apt/history.log`, `/var/log/dpkg.log`) with their own transaction
  boundaries. The execution tags its invocation (a recorded `Commandline`/marker
  plus the start/end window) so the Runix operation reconciles to the native log
  entry after the fact: "which dpkg transaction did Runix cause" is answerable,
  not inferred.

Reconciliation runs `request_id → correlation_id (C₂, the execution) → native
dpkg transaction`, so an audited Runix operation traces to the exact package
transaction it produced, and back.

## Package ownership

Not every installed package is Runix's to mutate. The general-apt helper owns a
bounded domain and refuses to step outside it, so two managers never fight over
the same dpkg state and a mutation can never brick the host.

- **rapt's `r-*` domain is off-limits.** `rapt` owns the r2u R-package packages
  (its `r-*` allowlist over its own root socket). The general-apt helper
  **refuses** to install, remove, or upgrade a package rapt owns; those go
  through rapt. This is the runtime enforcement of the scope note above — not
  only "don't wrap rapt" but "don't mutate rapt's packages by another path",
  which would leave two backends with conflicting views of the same packages. A
  cross-domain request is refused typed (`runix_package_not_owned`), never
  silently retargeted.
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

Ownership is checked at preview **and re-checked at execution** (it is part of
the pre-state the execution revalidates), so a package that became
owned/held/protected between request and execution is caught, not acted on.

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
is left with an execution **intent but no outcome** (`correlation_id` C₂ open),
while dpkg may be part-applied. Detectable, not self-healing:

- **Detection** is the durable-audit open-intent scan (per
  `durable-audit-contract.md`): an execution intent with no matching outcome for
  its `correlation_id`. As in A1 gate 6, Runix *detects* the open intent; it does
  not silently reconcile it.
- **Reconciliation** joins the open intent to ground truth — the native dpkg
  transaction (history/dpkg log window + marker) and the current dpkg status — to
  determine what actually happened, then writes a **terminal reconciliation
  outcome**: a new record carrying the same `request_id`, an `outcome` of
  `ok`/`failed`/`dpkg_broken`, and the observed post-state. The effect is never
  assumed from the mere existence of an intent.
- **Repair is an explicit, gated operation**, never automatic. `apt.configure`
  (`dpkg --configure -a` through the same privileged, audited boundary) is a
  first-class mutation with its own `request_id`, authorization, and audit — not
  a cleanup Runix performs on your behalf. A broken database is surfaced and left
  for a deliberate, authorized repair.

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
- `runix_stale_approval` — an execution failed revalidation (expiry, pre-state
  drift, or parameter/preview-hash mismatch); terminal, the caller must
  re-preview. Authorization failures at execution are `runix_unauthorized`.

All inherit `runix_error` via `runix::runix_abort()`; all mutation attempts,
including every one of these, emit durable audit records per the two-phase
rule (no silent error paths).

## Audit integration

apt mutations use the durable-audit two-phase write unchanged:

- **Intent** record made durable *before* taking the lock and issuing any
  effect. If it cannot persist, abort before touching the system.
- **Outcome** record after, with the real `effect_issued`, the `observed`
  post-state from `pkgstate`, `outcome`, `elapsed`, and the same
  `correlation_id`. `audit_persisted` is reported honestly on the result.

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
9. Execution revalidation: an execution carrying a valid `request_id` is
   refused, not executed, when (a) the actor or host differs, (b) authorization
   no longer holds, (c) the parameters/preview-hash differ, (d) the request has
   expired, or (e) the pre-state drifted since the preview. Only an execution
   that passes all five proceeds. Possession of the id alone never executes.
10. Axis separation: `apt.update` is `requires_authorization = TRUE` (it runs
    through the privileged helper and its polkit action) yet
    `approval_required = FALSE` (an agent runs it with no human approval); a
    package-changing op defaults `approval_required = TRUE`. The two flags move
    independently.
11. Async identity: a gated operation yields two attempts with **distinct**
    broker `correlation_id`s — C₁ for the approval request (`effect_issued =
    FALSE`, `outcome = approval_required`) and C₂ for the execution — joined by a
    single `request_id`. The execution never reuses C₁, and the record-sets join
    only by `request_id`.
12. Interrupted transaction: an execution whose outcome is never written leaves
    an open intent (C₂, no outcome) that is *detected* by the open-intent scan
    and *reconciled* to a terminal outcome carrying the same `request_id`, drawn
    from dpkg ground truth — never assumed `ok`. Repair happens only via the
    gated `apt.configure`, itself a fresh `request_id` + authorization + audit.
13. Package ownership: a request against a package in rapt's `r-*` domain is
    refused `runix_package_not_owned`; removal of an `Essential`/protected
    package is refused `runix_protected_package`; a mutation of a held package is
    refused with the hold in `observed` and never silently unheld. Each refusal
    still writes its intent audit record.

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
