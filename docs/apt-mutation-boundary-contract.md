# apt mutation boundary contract

Status: contract (pre-implementation). Covers roadmap gaps 2 and 3 for apt as
one design, because for apt they are the same design: authorization, the
global dpkg lock, transaction identity, and concurrency all meet at the
moment a package operation is issued. systemd and apt stay separate
*implementations* behind the shared effect-class policy
(`roadmap.md` "Authorization policy: effect class"); this contract is the apt
half. It builds on `phase2-mutation-contract.md` (the mutation discipline)
and `durable-audit-contract.md` (how every attempt is recorded).

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

## Effect classes for apt operations

Applying the roadmap's effect-class policy to apt:

| Operation | Class | Rationale |
|---|---|---|
| `apt.install`, `apt.remove`, `apt.purge` | human-gated | changes the trusted software set; hard to reverse |
| `apt.add_repo`, `apt.import_key` | human-gated | changes what the system will trust in future |
| `apt.upgrade`, `apt.dist_upgrade` | human-gated (default) | can pull large, cross-cutting changes |
| `apt.update` (list refresh) | agent-autonomous | no package-state change; only the lists lock |

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

Each apt operation mints a `correlation_id` (the same one the durable-audit
two-phase write uses). It identifies the **Runix operation** and is carried
on the result, any raised condition, and both audit records. Because apt and
dpkg keep their own logs (`/var/log/apt/history.log`,
`/var/log/dpkg.log`), the operation is tagged so the Runix
`correlation_id` can be reconciled with the native log entry (via the
recorded `Commandline`/marker and the start/end window). The point is that
"which dpkg transaction did Runix cause" is answerable after the fact, not
inferred.

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

## Typed errors and retryability

- `runix_unauthorized` — polkit/pkexec denied (terminal).
- `runix_apt_locked` — lock not acquired within the timeout (**retryable**).
- `runix_operation_failed` — apt/dpkg returned nonzero for a definite
  failure (terminal; carries the tool's diagnostic).
- `runix_dpkg_broken` — post-effect broken/half-configured state (terminal;
  carries the recovery hint).

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

The apt mutation surface is a new subsystem package (sibling to `rsystemd`,
consumer of `pkgstate` and the `runix` core), not part of `pkgstate` (which
stays read-only) and not part of `rapt`. It Imports the `runix` core for
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
