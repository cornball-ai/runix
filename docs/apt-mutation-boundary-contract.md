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
6. **The privileged boundary is not bypassable** (security review). Authorization
   is bound to **distinct immutable entrypoint paths** — `pkexec` selects the
   action by exec-path, not `argv` — one per risk class. The helper enforces the
   whole policy on the plan it commits, made **atomic under one `libapt-pkg`
   context** (C++ linked directly, no R) so the validated plan is the executed
   plan (no simulate-then-execute TOCTOU; this pulls libapt into v1). "No effect
   without durable intent" is enforced by a **broker-issued single-use effect
   receipt** the helper redeems — a broker capability **mandatory in v1 and built
   first**, no weaker fallback. The machine path does a **no-interaction
   authorization check**, so an auth challenge is a typed refusal, never a prompt.
   Preview is honest per operation.

## Scope and boundary

- **In scope:** the boundary for mutating installed-package state through
  apt/dpkg on the local host: install, remove, purge, upgrade, list refresh,
  configure (repair), and hold/unhold. **Repository and key changes are out of
  scope for v1**, deferred to their own hardened contract (see the metadata
  section).
- **Out of scope, read side:** querying package state is `pkgstate`, already
  built. apt mutations *use* `pkgstate` to read before/after state.
- **Out of scope, rapt:** `rapt` is the r2u binary R-package install backend
  (the `r-*` allowlist over its own root socket, a deliberate rejection of
  the polkit/PackageKit stack). It is **not** modified, broadened, or
  wrapped by this contract. The general-apt path defined here is separate
  from rapt. Any future unification (the `bsrm` discussion) is a separate
  decision with Dirk and is explicitly not assumed here.
- **Backend, revised:** the effect backend is no longer a purely Phase-4 choice.
  Whole-transaction enforcement must be **atomic under one lock** (see the helper
  boundary), which the `apt-get -s`-then-`apt-get` CLI bridge cannot provide
  (simulate is unlocked). v1 therefore requires a native helper linking
  **`libapt-pkg` C++ directly** (not RcppAPT — no R in the privileged helper) for
  gated mutations; the CLI bridge, under the usual discipline (`LC_ALL=C`,
  postcondition verification, injectable runner), is acceptable only for
  operations that need no whole-transaction atomic enforcement (e.g. `apt.update`).

## Risk and authorization metadata per operation

Applying the roadmap's authorization-and-risk policy to apt: each operation
carries explicit metadata, and the **fleet policy** reads it to decide
go/no-go, rather than a fixed "install vs update" verb category (an upgrade
can be as disruptive as an install). `preview_available` varies by operation
(column below) and is honest about what it can show — a real apt simulation for
package transactions, a synthesized state change for holds, and none for
`apt.configure`/`apt.update` (see Preview). `approval_required` below is the
**default**; the fleet policy may raise or lower it per operation and per host
role.

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

| Operation | reversible | disruptive | requires_authorization | approval_required (default) | preview_available |
|---|---|---|---|---|---|
| `apt.install` | partial (remove undoes it) | maybe (config, deps) | yes | yes | yes (apt simulate) |
| `apt.remove`, `apt.purge` | maybe (reinstall; purge drops config) | yes | yes | yes | yes (apt simulate) |
| `apt.upgrade`, `apt.dist_upgrade` | hard | yes | yes | yes | yes (apt simulate) |
| `apt.configure` (repair, `dpkg --configure -a`) | n/a (completes pending config) | maybe (maintainer scripts) | yes | yes | no (no faithful dry run) |
| `apt.hold` | yes (unhold) | no | yes | no | synthesized (flag change) |
| `apt.unhold` | yes (re-hold) | no | yes | yes | synthesized (flag change) |
| `apt.update` (list refresh) | n/a (no package change) | no | **yes** | no | no (metadata refresh, not a package plan) |

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

**Recommendation:** option 2 for v1, with a strict split of duties and
**verb-level** authorization enforced on the privileged side.

*Authorization is per risk class, bound to distinct entrypoint paths.* `pkexec`
selects a polkit action by the **executable-path** annotation on the action, not
by the program's arguments — it does not validate `argv`. So the verb cannot be
an argument the helper merely "checks": each risk class is a **distinct, immutable
helper entrypoint path**, and each path is bound to its own polkit action
(`ai.cornball.runix.apt.update`, `...apt.install`, `...apt.remove` [`auth_admin`],
`...apt.configure`, `...apt.hold`/`...apt.unhold`). The verb is fixed by *which
binary path* was invoked; the code reachable from the `update` entrypoint cannot
reach install/remove. Never rely on `command_line` or a caller-controlled
`argv[0]`. A caller who skips the R layer still lands on one specific path and its
one specific action — an umbrella action, or verb-by-argument, would collapse the
boundary.

*The machine path never prompts.* Merely registering no agent is not enough — a
desktop agent may already exist, and `pkexec` permits interactive authentication.
Machine mode performs an explicit **no-user-interaction authorization check**
(polkit `CheckAuthorization` with `AllowUserInteraction = FALSE`) and enters the
privileged effect path **only** when authorization is already granted without
interaction. A `challenge` or `deny` result returns a typed refusal
(`runix_approval_required` for a would-be human gate, `runix_unauthorized` for a
denial); the prompting path is never entered. The non-interactive check is made
first, and the helper is launched only on an already-authorized result — the
`--json` caller can never surface a prompt.

*The helper enforces the whole policy independently, and the plan it enforces is
the plan it commits.* Before acting, the native helper **recomputes the full
transaction** and enforces, on the trusted side, rapt ownership over the whole
computed set, holds, protected/essential packages, and the allowed option set —
the unprivileged preview is advisory only. Critically, **enforcement and
execution must be atomic under one lock/context**: `apt-get -s` simulates
*without* the lock, so a plan validated by simulation and then applied by a
separate `apt-get` run is a TOCTOU hole — another contender
(`unattended-upgrades`, a human) can change state in between, and the committed
transaction is then not the one that passed policy. v1's whole-transaction
guarantee therefore requires the native helper to link **`libapt-pkg` (the C++
library) directly** and, in one context, take the lock once, resolve the plan,
enforce policy on *that resolved plan*, and commit it — all under the one held
lock. RcppAPT is **prior art, not a helper dependency**: privileged R evaluation
is forbidden in the helper, so it uses `libapt-pkg` C++, never an R binding. This
pulls `libapt-pkg` into the **v1 boundary**, ahead of its former Phase-4 slot —
the `apt-get` CLI bridge cannot provide atomic whole-transaction enforcement, and
whole-transaction ownership/protection is a v1 requirement. The protocol is narrow
and non-evaluating: an enumerated verb (fixed by the entrypoint path) plus
validated, typed arguments (package names matched to a strict pattern), a
**sanitized environment**, **no shell or R evaluation**, and **no pass-through apt
flags or config paths**.

*No effect without a durable intent — enforced, not conventional.* The helper
must not act on trust that the caller "opened an intent"; a caller holding the
verb's authorization could otherwise `pkexec` the entrypoint directly and mutate
with no durable record. So opening the intent yields a **broker-issued effect
receipt** the helper redeems before committing; a missing, stale, mismatched, or
replayed receipt is a fail-closed refusal (`runix_no_intent`) *before* any effect.
This is a **hard v1 requirement, not a convention** — a root package transaction
is exactly where "no effect without durable intent" must hold — so the broker
receipt capability is built **first**, ahead of the helper (see the implementation
order in the verification ladder). The effect-receipt contract requires:

- a **distinct effect receipt**, separate from the outcome binding;
- **bound** to the `correlation_id`, the authenticated caller (`SO_PEERCRED`), the
  exact verb and resource, and the **preview-plan hash**;
- **short TTL and single use**;
- **durable issuance and durable redemption** — both survive a broker restart, so
  a receipt can be neither forged nor double-spent across a bounce;
- the helper **compares the atomic libapt-resolved plan against the bound hash**
  and refuses on mismatch;
- **redemption completed and fsynced before commit**;
- missing / stale / mismatched / replayed → `runix_no_intent`, before the effect.

Issuing and redeeming receipts is new broker behaviour (not just a record field),
specified with the schema work in "Broker schema dependency".

*The helper does only the effect; the unprivileged caller owns the audit.* The
caller opens the durable intent through the broker (audit actor = the real caller
via `SO_PEERCRED`, never root), invokes the helper, verifies post-state via
`pkgstate`, and closes the outcome on the same broker interaction — a privileged
helper that audited itself would record root or be unable to close the caller's
process-bound receipt. The lock is held **once by the atomic context** across
resolve-enforce-commit, with a bounded wait (see Global lock and concurrency); no
simulate-then-execute means no window in which the lock is dropped. Denial at the
polkit gate raises `runix_unauthorized`; no new resident daemon.

The authorization *descriptor* recorded in the audit (`authorized_via`) names the
per-verb polkit action actually checked, exactly as the systemd path records its
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
- **The intent receipt is a broker *capability*, not just a field.** Making "no
  effect without durable intent" a boundary guarantee (above) needs the broker to
  **issue** an effect receipt bound to the `correlation_id`, caller, verb,
  resource, and preview-plan hash — single-use, short-TTL, **durably** issued and
  redeemed across a restart — and to **verify/redeem** it for the privileged
  helper before commit. This is new behaviour, not just a record key. It is a
  **mandatory v1 prerequisite, built before the helper** (see the implementation
  order in the verification ladder); there is no weaker fallback.

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
  `rapt` owns the r2u R-package packages, identified by the predicate
  `^r-[a-z]+-[a-z0-9.]+$` (as `rapt` applies it in `r-pkg/R/manager.R`). rapt is
  **not modified** by this contract, so the predicate is **pinned here** and kept
  honest by a **cross-repo conformance test** asserting this contract's pattern
  still matches rapt's — a drift alarm, not a shared import. Two rules make
  ownership sound: (a) the pinned predicate is byte-for-byte rapt's; and (b) it is
  applied to **every package in the computed transaction**, not only the requested
  target, since apt pulls dependencies — an operation on a non-`r-` package that
  would drag in or remove an `r-` package still crosses the boundary. A
  cross-domain transaction is refused typed (`runix_package_not_owned`), never
  silently retargeted or partially applied.
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

- **Preview** is per operation and honest about what it can show (see the
  `preview_available` column):
  - **Package transactions** (`install`/`remove`/`purge`/`upgrade`) use apt's
    simulate (`apt-get -s`): the real plan (packages added/removed/held, download
    size), no effect.
  - **`apt.hold`/`apt.unhold`** have no apt simulation; the preview is a
    *synthesized* selection-flag before/after, marked as synthesized, not an apt
    plan.
  - **`apt.configure`** has no faithful dry run (`dpkg --configure -a` cannot be
    simulated); the preview reports the *pending-configuration set* it would act
    on and is explicit that the repair itself is not simulated.
  - **`apt.update`** is not a package transaction; its preview is which sources
    would be refreshed, not a package plan.
  Any preview is audited with `effect_issued = FALSE`.
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

- **Detection (v1) is root-only, and in v1 explicitly manual.** The durable sink
  is root-owned, mode `0640`, so an unprivileged Runix process cannot scan it and
  the broker exposes **no query API**. v1 detection is therefore a **root
  operator** (or a small root-only inspection command) reading the sink for an
  intent with no matching outcome for its `correlation_id` — not an unprivileged
  auto-scan, and not self-healing. As in A1 gate 6 the open intent is surfaced,
  not silently closed. A first-class root-only "open intents" query is the natural
  follow-up, pairing with the broker's missing query API.
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
- `runix_no_intent` — the helper was invoked without a valid effect receipt
  (missing, stale, mismatched, or replayed); fail-closed *before* any effect.
  Enforced by the broker's **mandatory** receipt capability (built first in v1;
  see "Broker schema dependency").
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
- **Effect** is the helper's only job — under one libapt context it takes the
  lock, recomputes and policy-checks the transaction, and commits it atomically;
  it redeems the intent receipt first and writes no audit.
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
    an open intent with no matching outcome for its `correlation_id`, found by a
    **root-only** scan of the sink (unprivileged R cannot read the `0640` sink;
    the broker has no query API) and surfaced as unreconciled; the dead
    `correlation_id` receives no outcome, and no reconciliation record is written
    against the shipped broker. Repair is only via the gated `apt.configure`.
13. Package ownership over the whole transaction: an operation whose **computed
    plan** touches any package matching rapt's exact predicate
    (`^r-[a-z]+-[a-z0-9.]+$`) — target or pulled dependency — is refused
    `runix_package_not_owned` and not partially applied; removal of an
    `Essential`/protected package is refused `runix_protected_package`; a held
    package's mutation is refused with the hold in `observed`. Each refusal still
    writes its intent record.

Helper-boundary conformance (against the native helper, not just the R fixture):

14. Verb-level authorization: the `apt.update` action does **not** authorize
    `apt.install`/`apt.remove`; the helper checks the polkit action for the exact
    verb it was asked to perform, so a caller that bypasses R and invokes the
    helper for a gated verb still meets that verb's `auth_admin`.
15. Independent enforcement: handed a preview that claims a plan is clean, the
    helper still **recomputes** the transaction and refuses on ownership / holds /
    protected packages; it rejects any pass-through apt flag or config path
    (`-o`/`-c`/`--force*`) and any package name outside the strict pattern. The
    unprivileged preview never authorizes the effect.
16. Preview honesty: `preview_available` matches the table — real `apt-get -s`
    for package transactions, a *synthesized* flag change for hold/unhold, and
    none for `apt.configure`/`apt.update` — and every preview audits
    `effect_issued = FALSE` and marks synthesized/none as such.
17. Predicate drift: a cross-repo test asserts the pinned ownership predicate is
    byte-for-byte the pattern rapt applies in `rapt` `r-pkg/R/manager.R`; drift
    fails the test rather than silently diverging.
18. Plan ≠ execution is refused: with package state changed between resolve and
    commit, the atomic libapt context fails closed — it never commits a
    transaction other than the one policy enforced. (A simulate-then-execute
    backend that would commit the changed plan fails this test, which is the
    point.)
19. No intent, no effect: invoking a helper entrypoint directly without a valid
    effect receipt is refused `runix_no_intent` and issues no effect. The broker
    receipt capability is a v1 prerequisite, so this is a required gate — a
    replayed or state-changed receipt (plan-hash mismatch) is refused too.
20. Entrypoint isolation: the `apt.update` entrypoint/action cannot reach
    install/remove code — mutating packages requires the install/remove entrypoint
    and its `auth_admin` action; a caller holding only the update action cannot
    install or remove.
21. Noninteractive machine path: a `--json` invocation of an auth-required verb
    returns a typed refusal (`runix_approval_required` / `runix_unauthorized`) via
    a no-interaction authorization check (`AllowUserInteraction = FALSE`) and never
    enters the prompting path — even if a desktop polkit agent is present.

## Verification ladder

Fixtures cannot reproduce the parts of apt that make it dangerous — the dpkg
frontend lock under real contention, maintainer scripts, a genuinely interrupted
transaction, conffile prompts, or a partially-configured database. The
conformance tests above (fixture level, against an injectable runner/lock/sink)
are necessary but not sufficient. The full ladder, and the order it is built in:

    broker effect-receipt contract + implementation
      ->  libapt-pkg helper  ->  pkgops R API  ->  fixture tests
      ->  minimal destructive disposable-VM gate

Implementation **begins with the broker effect-receipt capability**, not
`pkgops`: the receipt is the boundary guarantee everything else leans on, so it
lands first — an R API is meaningless if a direct `pkexec` of an entrypoint can
bypass it. Only then the `libapt-pkg` helper, then the `pkgops` R API, then
fixtures, then the VM gate.

The final stage is a **minimal** destructive acceptance on a disposable VM (the
A1 canary harness, `deploy/canary/`), **never the troy-g5 host**: a harmless
local test package and repository exercise a real install/remove/upgrade, a real
held/protected refusal, real lock contention, and a real interrupted transaction
with its reconciliation — the behaviours fixtures can only stub. It is the apt
arc's last gate, not a feature of its own.
