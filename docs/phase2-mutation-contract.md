# Phase 2: Mutation Contract

Drafted 2026-08-07, before any Phase 2 implementation. Phase 1 made Runix
excellent at *reading* a system; Phase 2 lets it *change* one, under a
discipline strict enough that an AI agent or orchestration harness can be
trusted to drive it. systemd mutations land first; apt mutations follow,
behind rapt's privileged daemon.

This contract extends, and never contradicts, two existing documents:
`phase1-introspection-contracts.md` (functional core → imperative
boundary; typed conditions; injectable runners; data-in/data-out) and
`rctl-json-contract.md` (the JSON envelope, exit codes, deterministic
encoding). Read both first.

## Principles

1. **Read-only stays the default.** A mutation only ever happens through an
   explicit mutation verb. Nothing in the introspection API acquires side
   effects.
2. **Effect verbs are explicit and imperative** (`systemd_start()`,
   `systemd_restart()`, `apt_install()`), never overloaded onto a query.
3. **Every mutation is previewable without doing it** — a dry-run that
   reports the intended change and its current-state delta, computed the
   same way the real run computes it.
4. **Idempotence is contractual, not incidental.** A mutation that finds
   the system already in the desired state reports `changed = FALSE` and
   does nothing. Running it twice is safe by design.
5. **Request, observe, settle — never request-and-assume** (the Phase 1
   bridge discipline, now load-bearing). After issuing an effect, verify
   the postcondition and report the *observed* result, not the intent.
6. **Reuse service-level authorization where provided.** systemd, logind,
   and NetworkManager run their own polkit checks over D-Bus; Runix
   inherits them and reports authorization failures as typed errors. It
   does not reimplement policy. apt, having no such layer, goes through
   rapt's daemon.
7. **Arbitrary R evaluation is never a privilege mechanism** (carried from
   the agent-facing design). No mutation path evaluates caller-supplied
   R, and no privileged component runs R as root to accomplish a mutation.
8. **Every mutation is auditable.** Each effect emits an audit record
   (below), regardless of channel.

## The result object

Every mutation verb returns an S3 `runix_result` list (data-in / data-out,
no handles), with these fields always present:

```r
list(
  operation     = "systemd.restart", # dotted verb
  resource      = "cups.service",     # the object acted on
  changed       = TRUE,               # verb-specific functional effect
  state_changed = TRUE,               # raw before/after field difference
  preview       = FALSE,              # was this a dry-run?
  before        = list(...),          # observed pre-state (verb-specific)
  after         = list(...),          # observed post-state (NA in preview)
  planned       = list(...),          # the intended change (always present)
  audit         = list(...)           # the audit record (below)
)
```

- `changed` / `state_changed`: the two idempotence signals defined under
  "Idempotence" below — functional effect vs raw observed transition.
- `before` / `after`: verb-specific observed state, drawn from the Phase 1
  introspection functions (e.g. `active_state`, `unit_file_state`), so a
  mutation's evidence is the same data a query would return. `after` is
  `NA` when `preview = TRUE`.
- `planned`: what the verb *would* do, always computed — this is what a
  dry-run returns, and what a real run records before acting.

## Preview / dry-run

Every mutation verb takes `preview = FALSE` as its final argument. With
`preview = TRUE`:

- no effect is issued;
- `planned` is fully populated and `before` reflects live state;
- `changed` is the prediction (would this change anything?);
- `after` is `NA`;
- authorization is still checked as far as it can be without acting (a
  preview must not report "would succeed" for an operation the caller is
  not permitted to perform — see Authorization).

The dry-run must be computed by the same code path as the real run, so a
preview cannot silently diverge from what execution does. Where the
backend offers a native dry-run (`systemctl --dry-run`), it is used to
cross-check, not to replace, the R-level plan.

## Idempotence: `state_changed` vs `changed`

Two distinct booleans, because agents need both the raw transition and the
semantic effect, and conflating them was self-contradictory (stopping a
`failed` unit *does* move `failed → inactive` yet is not a functional
change). Both are always present in `runix_result`:

- **`state_changed`** — the raw, mechanical fact: did any observed field
  (`active_state`, `sub_state`, `unit_file_state`, `main_pid`) differ
  between `before` and `after`? Purely computed from the two observations.
- **`changed`** — the verb-specific *functional* effect: did the operation
  accomplish its purpose as a state change? Defined per verb below.

| Verb | `changed = TRUE` (functional) | effect issued? |
|---|---|---|
| `systemd_start` | unit was not `active` before and is `active` after | only if not already `active` |
| `systemd_stop` | unit was in the running set before (not `inactive`/`failed`) and is not-running after | issued unless already `inactive` |
| `systemd_restart` | postcondition met: unit reached its per-type "up" state (below) | always |
| `systemd_enable` | `unit_file_state` was not `enabled` before and is `enabled` after | only if not already `enabled` |
| `systemd_disable` | `unit_file_state` was in the enabled set before and is `disabled`/`masked` after | issued unless already `disabled` |

Pinned edge cases (deterministic):

- **`systemd_stop` on a `failed` unit**: desired state (not-running) is
  already met, but the verb still issues `systemctl stop` to clear the
  failed activation (valid in systemd). Result: `state_changed = TRUE`
  (`failed → inactive` is a real field change), `changed = FALSE` (no
  functional stop happened — it was already not running). An agent wanting
  the cleanup reads `state_changed`; one asking "did I stop something
  running" reads `changed`.
- **already-desired `start`/`enable`**: both `FALSE`, no effect issued
  (true idempotence — the backend is not invoked).

### `restart` postcondition is unit-type-aware

`restart` always issues the effect (never idempotent) and its `changed` is
**postcondition-met**, not a universal `MainPID` rule — because `MainPID`
is meaningless for many unit types:

- **service (`Type` with a main process: simple/exec/notify/forking)**:
  postcondition = `active` after, with a *new* `MainPID` when the type has
  one. `main_pid` before/after is exposed as evidence.
- **oneshot service** (`RemainAfterExit`): `MainPID` is typically 0;
  postcondition = `active` (or the expected `exited` sub-state) after. No
  PID comparison.
- **socket / timer / path / mount / target**: no meaningful main process;
  postcondition = the unit's `active_state` returns to `active`. `main_pid`
  is `NA` in the evidence, not a failure.

So `changed = TRUE` for restart means "the restart completed and the unit's
per-type up-postcondition holds afterward"; PID/timestamp evidence is
carried in `before`/`after` when the type provides it, and its absence is
data, never an error. A restart that does not reach the postcondition is
`changed = FALSE` with the failure visible in `after` (and surfaced as a
`runix_operation_failed` error if the job itself failed).

## Timeout and cancellation

- Every mutation verb takes `timeout` (seconds, default per verb; systemd
  unit operations default 90s to match systemd's own `TimeoutStartSec`
  neighbourhood). A backend operation exceeding it is abandoned and
  reported as a typed `runix_timeout` error — retryable `false` by default
  (the operation may have partially applied; re-running is the caller's
  decision, informed by a fresh query).
- **A timeout never leaves a lie — enforced by the error payload, not
  prose.** `runix_timeout` and `runix_cancelled` both carry, in addition to
  `resource` and `elapsed`, an **`observed`** field: the post-state read
  the same way `after` is read (`active_state`, `sub_state`,
  `unit_file_state`, `main_pid`). If that post-observation itself fails
  (e.g. `systemctl show` also hangs or the tool is gone), `observed` is set
  to `NA` and an **`observed_failed`** boolean is `TRUE` with a reason
  string — the contract is that the caller can always distinguish "here is
  the real state after the abandoned wait" from "state could not be
  determined", and is never handed silence. The rctl error envelope
  carries these fields alongside the class vector.

### Cancellation, operationally

Cancellation is defined by mechanism, and the mechanism deliberately avoids
a long-running R-owned child — so rsystemd keeps its zero-R-dependency
posture (no `processx`; the blocking-C interruptibility problem is
structured out rather than dependency-managed).

- **The effect and the wait are separated.** For start/stop/restart, Runix
  issues `systemctl <verb> --no-block <unit>`, which queues the job to
  PID 1 and **returns immediately** (a short-lived child, not a blocking
  wait). Runix then runs its own poll loop in R — repeatedly reading
  `systemd_unit_info(unit)` — until the postcondition holds or `timeout`
  elapses. enable/disable are fast synchronous symlink operations
  (`systemctl enable/disable`), no `--no-block` and no meaningful wait.
- **The wait is a plain R loop, so it is naturally interruptible.** R
  services interrupts between iterations; SIGINT (interactive) or an
  orchestrator cancel breaks the poll without any child to signal or reap,
  because `systemctl --no-block` already exited. There is no SIGTERM/
  SIGKILL/tree-reaping step because there is no persistent R-spawned
  process — its absence is the design, not an omission.
- **Cancellation aborts Runix's observation, not systemd's job** — and here
  that is structural, not a caveat bolted on: the job was handed to PID 1
  before the wait began. On cancel or timeout the verb stops polling, reads
  final state into `observed`, and returns. systemd may still be carrying
  the job to completion; the `observed` field (and a fresh query later) is
  how the caller learns the real outcome.
- **After the R call returns, nothing Runix spawned is still running** — by
  construction, since each `systemctl` invocation is short-lived. The
  systemd job is systemd's to own.
- The apt slice (behind rapt, later) has its own long-running-transaction
  shape; its cancellation model is rapt's daemon's concern and gets its own
  contract entry. This section governs the systemd slice only.

## Authorization

- systemd verbs reach the manager over D-Bus, which performs its own
  polkit check against the relevant action
  (`org.freedesktop.systemd1.manage-units` for start/stop/restart,
  `manage-unit-files` for enable/disable). An authorization denial is a
  typed `runix_unauthorized` error carrying the polkit action and
  `resource`; it is **not** an exit-2 usage error — it is exit 1
  (operation refused), because the request was well-formed.
- Cases needing explicit policy handling are documented per verb: headless
  (no active session) invocation needs a polkit rule or an auth agent, and
  that requirement is reported, not silently worked around.
- Preview under insufficient authorization reports `planned` plus an
  `authorized = FALSE` marker in the result, so a dry-run never implies an
  effect the caller cannot actually cause.
- apt mutations carry no service-level authz; they go through rapt's
  daemon, whose existing allowlist model is the boundary. Runix does not
  add a second privileged path.

## Audit record

Every effect (real or preview) emits an audit record, present as the
result's `audit` field and, in a running daemon/harness context, written
to a structured log:

```r
list(
  operation = "systemd.restart",
  resource  = "cups.service",
  preview   = FALSE,
  changed   = TRUE,
  state_changed = TRUE,
  actor     = "<uid/name of caller>",
  authorized_via = "polkit:org.freedesktop.systemd1.manage-units",
  time      = <POSIXct UTC>,
  outcome   = "ok" | "unauthorized" | "timeout" | "cancelled" |
              "failed" | "error"
)
```

Audit records are data, encoded by the same deterministic rules as
everything else. A preview is audited too (with `preview = TRUE`,
`outcome = "ok"`), so "what did this agent try" is answerable, not just
"what did it change".

## rctl and the envelope

Mutation verbs surface through `rctl` as new operations
(`services.start`, `services.restart`, ...). The envelope is unchanged
from `rctl-json-contract.md`: the `runix_result` is the `result` payload
on success; typed mutation errors map to the existing class-vector error envelope with
their documented retryability:

- `runix_unauthorized` — polkit denied the action (exit 1);
- `runix_timeout` — the wait exceeded `timeout` (exit 1);
- `runix_cancelled` — the wait was interrupted (exit 1);
- `runix_operation_failed` — the systemd job itself failed (e.g. the unit
  went `failed` on start, or restart did not reach its postcondition;
  exit 1).

`runix_timeout` and `runix_cancelled` additionally carry `observed` (or
`observed: null` with `observed_failed: true` and a reason) in the error
object, so the machine-readable failure is as truthful about post-state as
the success result is. `runix_operation_failed` carries the observed
`after` state that shows the failure.

Two additions, both backward-compatible:

- `--preview` is the CLI spelling of `preview = TRUE`. A previewed
  mutation is a successful (`ok: true`) call whose result carries
  `preview: true` — it is not an error.
- Mutations are the point of the exit-code discipline: `unauthorized` and
  `timeout` are exit 1 (operation refused/failed), bad arguments are
  exit 2, a missing subsystem/tool is exit 3 — unchanged.

`capabilities` gains a per-operation `mutates` boolean so an agent can
enumerate which operations have effects before calling any.

## Scope and ordering

In scope for the first Phase 2 slice (rsystemd):
`systemd_start`, `systemd_stop`, `systemd_restart`, `systemd_enable`,
`systemd_disable`, each with preview, idempotence, timeout/cancellation,
service-level authz, audit, and the `runix_result` return.

Deferred to the apt slice (behind rapt): `apt_install`, `apt_remove`,
`apt_update` — same result/audit/preview shape, authorized by rapt's
daemon rather than polkit.

Explicit non-goals for Phase 2: `daemon-reload` orchestration beyond what
a unit-file change requires; masking/unmasking (a later slice); any
declarative multi-resource apply (that is Phase 7); network mutations
(rnetwork, later). One resource per call; batching is a caller/harness
concern built on these primitives, not a new privileged path.
