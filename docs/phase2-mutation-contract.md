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
  operation   = "systemd.restart",   # dotted verb
  resource    = "cups.service",       # the object acted on
  changed     = TRUE,                 # did state actually change?
  preview     = FALSE,                # was this a dry-run?
  before      = list(...),            # observed pre-state (verb-specific)
  after       = list(...),            # observed post-state (NA in preview)
  planned     = list(...),            # the intended change (always present)
  audit       = list(...)             # the audit record (below)
)
```

- `changed`: the idempotence signal. `FALSE` means the observed
  post-state already equalled the desired state and no effect was applied.
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

## Idempotence, per verb

| Verb | Desired state | `changed = FALSE` when |
|---|---|---|
| `systemd_start(unit)` | active | already `active` |
| `systemd_stop(unit)` | inactive | already `inactive`/`failed` |
| `systemd_restart(unit)` | freshly (re)started | never idempotent — restart always acts; `changed` reflects whether it was running before |
| `systemd_enable(unit)` | enabled | `unit_file_state` already `enabled` |
| `systemd_disable(unit)` | disabled | already `disabled`/`masked` |

`restart` is the honest exception: it is a deliberate bounce, so it always
issues the effect, but its result still reports `before`/`after` so a
caller sees the transition.

## Timeout and cancellation

- Every mutation verb takes `timeout` (seconds, default per verb; systemd
  unit operations default 90s to match systemd's own `TimeoutStartSec`
  neighbourhood). A backend operation exceeding it is abandoned and
  reported as a typed `runix_timeout` error carrying `resource` and the
  elapsed time — retryable `false` by default (the operation may have
  partially applied; re-running is the caller's decision, informed by a
  fresh query).
- **A timeout never leaves a lie.** On timeout the verb still observes and
  reports actual post-state where it can, so `after` is truthful even when
  the wait was abandoned.
- Cancellation: mutations run through the interruptible subprocess/D-Bus
  path (never a blocking C call R cannot interrupt), so an interactive
  Ctrl-C or an orchestrator's cancel signal aborts the *wait*; the same
  "observe actual state" guarantee applies. Cancellation mid-effect is
  reported as `runix_cancelled`, again with observed post-state.

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
  actor     = "<uid/name of caller>",
  authorized_via = "polkit:org.freedesktop.systemd1.manage-units",
  time      = <POSIXct UTC>,
  outcome   = "ok" | "unauthorized" | "timeout" | "cancelled" | "error"
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
on success; typed mutation errors (`runix_unauthorized`, `runix_timeout`,
`runix_cancelled`) map to the existing class-vector error envelope with
their documented retryability.

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
