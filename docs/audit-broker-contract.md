# Audit broker contract

Status: stub (pre-implementation). Created because the durable-audit authority
matrix (`durable-audit-contract.md`) needs a **system-durable** path for
unprivileged system-scope mutations, and that path must be a dedicated
component, not a reuse of any mutation helper. This file records the
requirements; it is filled out before the broker is built.

## Why a separate component

An unprivileged R process that systemd's polkit authorizes to restart a
**system** unit cannot append to the root-owned system sink. The v1 answer is
the caller-owned sink with an honest `audit_scope = "caller"` and
`system_durable_audit = FALSE` (ratified in `durable-audit-contract.md`). The
**strong** answer, and the gate for autonomous fleet-wide system mutation, is
a privileged broker that appends the caller's record to the system sink.

It is **not** the apt boundary's `pkexec` helper. Those jobs differ:

- the apt helper performs an *authorized mutation* (installs, removes);
- the audit broker only *appends validated records*.

Merging them enlarges both privilege surfaces, and the apt helper's `pkexec`
password prompt would undermine autonomous systemd operation (an agent
restarting a service must not be forced through a prompt just to record the
audit). The broker is small, single-purpose, and non-interactive.

## Requirements (to specify)

- **Credential-aware.** The actor is derived from the peer's process
  credentials (`SO_PEERCRED` on a local `AF_UNIX` socket), **never** from the
  payload. A caller cannot claim to be someone else.
- **Append-only.** The broker does nothing but validate and append. No
  mutation, no arbitrary I/O, no shelling out on behalf of the caller.
- **Owns the path.** Caller-supplied destination paths are rejected; the
  broker writes only its configured system sink.
- **Schema-validated.** Records are validated against the durable-audit record
  schema before append; malformed records are rejected, not written.
- **Same durability discipline** as the file sink: whole-line append, fsync,
  parent-directory fsync on create/rotation, honest failure reporting.
- **Bounded and non-interactive.** No prompts, no long-held caller state; a
  request is a single validated append.

## Alternative to evaluate: journald

Before building a bespoke socket writer, evaluate **journald** as a weaker,
already-present broker: structured records written to the system journal
(`sd_journal_send` / `systemd-cat`), which is root-owned, append-only, and
credential-stamped by the journal. Trade-offs to weigh: queryability and
schema fidelity of JSONL-in-journal vs a purpose-built sink; retention and
rotation controlled by journald config rather than the sink; and whether the
journal's own guarantees meet the durable-audit invariants. If journald
suffices, it avoids a new privileged service entirely.

## Relationship to the rest

- Consumes the durable-audit record schema and the two-phase discipline from
  `durable-audit-contract.md`.
- Its presence flips `system_durable_audit` to `true` in
  `rctl capabilities` (`rctl-json-contract.md`), which is what a fleet policy
  gates autonomous system mutation on.
- Independent of the apt mutation boundary; the two privileged paths stay
  separate.
