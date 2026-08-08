# Durable audit contract

Status: contract (pre-implementation). Written before the sink exists, so
implementation follows the spec rather than the reverse. Amends the audit
section of `phase2-mutation-contract.md` and closes roadmap gap 1 (durable
audit sink, including the error-path audit finding).

## Purpose

Phase 2 already builds an in-memory audit record and hangs it on every
mutation result. What is missing is a *durable* record: a place an operator
or agent can read afterward to reconstruct what Runix did to the system,
that survives the process exiting and cannot be silently lost or torn by a
second writer. This contract defines that sink and the guarantees attached
to it.

The property we are buying: **no effect is ever issued to the system
without a durable record of the attempt, and the result never claims the
record is durable when it is not.**

Non-goals for v1: a SIEM, real-time streaming, cryptographic tamper-proofing
(see "Tamper posture"), and shared/networked-filesystem sinks (flock
semantics on NFS are unreliable; single host, local disk).

## The four facts a record must keep separate

The core discipline. These are orthogonal and must never be conflated in the
record or in the result object:

1. **`outcome`** — what happened: `ok`, `no_op`, `preview`, `unauthorized`,
   `timeout`, `cancelled`, `failed`, `error`.
2. **`effect_issued`** — did Runix actually hand the mutating command to the
   backend? `TRUE`, `FALSE`, or `"unknown"`. This is not derivable from
   `outcome`: a `timeout` has `effect_issued = TRUE` with an unconfirmed
   result; an `unauthorized` caught before the call has `effect_issued =
   FALSE`.
3. **`observed`** — the post-state Runix actually read (may be `NA` when the
   observation itself failed, per the Phase 2 `observed_failed` rule).
4. **`audit_persisted`** — did the durable write of *this* record succeed?
   A boolean on the result object. **Never report `audit_persisted = TRUE`
   when the sink write or its fsync failed.** This is the one fact about the
   audit system's own integrity, and it must be honest even (especially)
   when everything else went fine.

A reader must be able to answer "did this touch the machine?" (`effect_issued`)
independently from "did it work?" (`outcome`) and from "do I trust this log
line exists on disk?" (`audit_persisted`).

## What gets audited

Every attempt that reaches the effect boundary, not only successes. This is
the roadmap gap-1 error-path finding: today `timeout` / `cancelled` /
`failed` / `unauthorized` carry `observed` state on the condition but emit
no audit record. Under this contract they all emit records.

- **Effect issued** (`ok`, `no_op` after issue, `timeout`, `cancelled`,
  `failed`): mandatory record.
- **No effect issued** (`preview`, pre-issue `unauthorized`, an idempotent
  `no_op` detected before the call): still recorded, with
  `effect_issued = FALSE`. Preview answers "what did this agent try",
  which is worth as much as what it changed.

## Two-phase write: intent then outcome

The mechanism that delivers "no un-recorded effect." A single mutation emits
up to two records sharing one `correlation_id`:

1. **Intent record**, written and durable **before** the effect boundary:
   the planned operation, resource, actor, planned authorization, and
   `effect_issued = FALSE`, `outcome = "intent"`. If this write cannot be
   made durable, the mutation **aborts before issuing any effect** and
   raises `runix_audit_error`. No effect is issued that we could not first
   record.

2. **Outcome record**, written **after** the effect boundary: same
   `correlation_id`, the real `effect_issued`, the `observed` post-state,
   `outcome`, and `elapsed`. If this write fails, the effect has already
   happened and cannot be recalled; the result reports
   `audit_persisted = FALSE` with the persistence error, the record is
   emitted best-effort to the fallback channel (below), and the durable
   intent record still proves the attempt occurred.

A reader joins the pair on `correlation_id`. An intent with no matching
outcome means the process died between issuing and confirming: itself a
diagnostic signal, not a hole. Non-effect paths (preview, pre-issue denial)
write a single record and skip the outcome phase.

Paths that issue no effect and can persist their single record do not need
the two-phase split, but they use the same `correlation_id` and schema.

**Approval boundary interaction.** For a machine-mode gated operation
(`apt-mutation-boundary-contract.md`), the intent record is written and made
durable, then the call returns `approval_required` carrying that
`correlation_id` and issues no effect. This is exactly why intent-first
matters: a later out-of-band authorization references a real, recorded
operation, and the authorized resume attaches its outcome record to the same
`correlation_id`. An approved-and-resumed operation is one intent plus one
outcome, as usual; a never-approved one is an intent that stays open, which is
an honest, queryable state rather than a silent effect.

## Record schema (persisted line)

Append-only JSONL: one JSON object per line, deterministic key order,
encoded by the same rules as the rest of Runix (`rctl-json-contract.md`).
Extends the Phase 2 in-memory record with the persistence and correlation
fields:

```jsonc
{
  "schema_version": 1,
  "correlation_id": "<time-ordered unique token, stable across the pair>",
  "phase": "intent" | "outcome",
  "host": "<nodename>",
  "pid": 12345,
  "operation": "systemd.restart",
  "resource": "cups.service",
  "actor": "<uid/name of caller>",
  "scope": "system" | "user",
  "preview": false,
  "authorized_via": "polkit:org.freedesktop.systemd1.manage-units",
  "effect_issued": true,
  "changed": true,
  "state_changed": true,
  "observed": { "active_state": "active" },
  "completion_method": "invocation_id",
  "job_result": "done",
  "outcome": "ok",
  "elapsed": 0.42,
  "time": "2026-08-08T12:00:00Z"
}
```

The `runix_result` audit sublist and the mutation error condition gain the
same `correlation_id`, `effect_issued`, and `audit_persisted` fields, so the
in-memory result, the raised condition, and the on-disk line all cross-
reference. This is the amendment to the Phase 2 audit record.

## Correlation IDs

Every mutation attempt mints one `correlation_id`, unique per attempt and
stable across (a) the intent record, (b) the outcome record, (c) the
`runix_result`, and (d) any raised condition. It correlates the **Runix
operation**; systemd's `InvocationID` correlates the **systemd job** and
continues to live in `completion`. The id must be time-orderable (ULID or
UUIDv7 shape) so a sorted sink is chronological without parsing timestamps.
Generation is an implementation detail, but it must not collide across
concurrent writers on the same host (include host+pid entropy).

## Durability and atomicity

- **Append-only.** Existing lines are never rewritten or truncated in place.
- **Whole-line writes.** The complete JSON line plus newline is assembled in
  memory and written in one `write()` to a descriptor opened `O_APPEND`. No
  partially-written lines, no interleaving of a line with another writer's.
- **fsync before the claim.** For any record whose companion effect was or
  will be issued, the sink is `fsync`d (and the directory entry `fsync`d on
  first create) **before** the mutation returns a result that claims
  `audit_persisted = TRUE`. The durable record precedes the caller learning
  the effect happened. A `durability` policy knob (`fsync` default, `flush`,
  `none`) exists for high-frequency non-effect records, but effect-issuing
  paths default to `fsync` and downgrading them is an explicit operator
  choice.

## Concurrent writers

Multiple agents (separate R processes) may write one sink.

- The append + fsync critical section is guarded by an advisory `flock`
  (`LOCK_EX`) on the sink, because a full JSONL line can exceed the
  atomic-`write` size (`PIPE_BUF`) and `O_APPEND` alone then does not
  guarantee non-interleaving.
- Records carry `host` + `pid` + `correlation_id`, so concurrent writers
  remain distinguishable even if two attempts race.
- One sink file per host. Shared/networked-filesystem sinks are out of scope
  (advisory locking is not reliable across NFS); forwarding to a central
  collector is a downstream concern, not the sink's job.

## Permissions

The sink records who did what as root; it is security-sensitive.

- Default path: `/var/log/runix/audit.jsonl` for system scope,
  `$XDG_STATE_HOME/runix/audit.jsonl` (fallback `~/.local/state`) for user
  scope.
- Directory mode `0750`, file mode `0640`, owned by `root` and an audit
  group (`adm` or a dedicated `runix-audit`). Never world-readable: resource
  names and actors are not public.
- On open, verify the sink is not world-writable and not a symlink to
  somewhere unexpected; refuse to write to a hijackable sink and raise
  `runix_audit_error` rather than append to it.

## Rotation

- Rotate by **rename then create** (`audit.jsonl` -> `audit.jsonl.1`, fresh
  file created), never by truncate-in-place. `copytruncate`-style external
  logrotate is wrong here: it races the appenders and drops records. Use
  Runix-internal size/age rotation, or `logrotate` in `create` (not
  `copytruncate`) mode with the same ownership/mode.
- Rotation takes the same `flock` as appends, so no writer straddles the
  swap.
- Retention count/age is operator configuration.

## Tamper posture (v1, stated honestly)

v1 is tamper-*evident-lite*, not tamper-*proof*: append-only discipline,
restrictive permissions, and per-effect fsync. An adversary who already has
write access to the sink (i.e. root, the same principal running the
mutations) can alter it. The guarantees are against accidental loss, torn
lines, concurrent-writer interleaving, and casual after-the-fact editing,
not against a determined privileged attacker. A per-record hash chain (each
line commits to the hash of the previous) is a documented future option for
real tamper-evidence; it is out of scope for v1 and must not be implied by
the word "audit."

## Behavior when persistence itself fails

The case the rest of the contract exists to get right.

- **Intent write fails (pre-effect):** fail closed. Do not issue the effect.
  Raise `runix_audit_error`. The system is untouched and the caller knows
  why. This is the strong guarantee.
- **Outcome write fails (post-effect):** the effect already happened; do not
  pretend otherwise. The result carries `audit_persisted = FALSE` and the
  persistence error; the record is written best-effort to the fallback
  channel; the (durable) intent record already proves the attempt. Do not
  raise in a way that suggests the effect did not occur; surface both facts.
- **Fallback channel:** when the primary sink is unavailable, records go to
  `stderr` as JSONL and, where available, to the system journal
  (`systemd-cat` / syslog), tagged so they can be reconciled later by
  `correlation_id`. The fallback is best-effort and never sets
  `audit_persisted = TRUE`.
- **The invariant:** `audit_persisted = TRUE` means the record is on stable
  storage in the primary sink and fsync returned success. Nothing else may
  set it true.

## Where this lives

The sink writer is subsystem-neutral cross-cutting machinery, so it belongs
in the `runix` core alongside the conditions/runner/result spine, not in
rsystemd or a future rapt. Subsystems build the domain audit *content* (as
rsystemd's `new_audit` does today); the core owns the *persistence
mechanism* (`audit_emit(record, sink, policy)`, the two-phase driver, the
lock, the fsync, the fallback). The sink and clock are injectable so tests
run offline and deterministically, matching the runner/sleeper pattern. If
deterministic JSON encoding pulls in a dependency, the encoder is injected
so the core keeps its zero-dependency posture (the same encoder rctl already
uses can be passed in).

## Conformance tests

Against an injectable sink (temp file) and injectable clock/fsync:

1. A successful mutation writes an intent line then an outcome line sharing
   one `correlation_id`; the result has `audit_persisted = TRUE`.
2. Intent-write failure aborts before any effect is issued and raises
   `runix_audit_error`; the sink has no outcome line and the system is
   untouched (verified via the injected runner recording zero effect calls).
3. Outcome-write failure leaves the effect issued, sets
   `audit_persisted = FALSE` with the error, and still leaves the durable
   intent line on disk.
4. Each error outcome (`timeout`, `cancelled`, `failed`, `unauthorized`)
   emits a record with the correct `effect_issued` (the gap-1 regression:
   these must no longer be silent).
5. Two concurrent writers produce only whole, parseable lines (no torn or
   interleaved JSON), each attributable by `host`+`pid`+`correlation_id`.
6. A world-writable or symlinked sink is refused with `runix_audit_error`.
7. Rotation preserves every prior record and never truncates a live sink.
8. `preview` writes exactly one record with `effect_issued = FALSE` and
   issues no effect.
