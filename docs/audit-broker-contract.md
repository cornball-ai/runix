# Audit broker contract

Status: contract (pre-implementation). The strong resolution of the
durable-audit authority matrix (`durable-audit-contract.md`): the privileged,
single-purpose component that lets an **unprivileged** system-scope mutation
get a **system-durable** audit record. Its existence is what allows
`system_durable_audit = TRUE` and, with it, honest autonomous fleet-wide
system mutation. Until it exists, v1's caller-owned sink stands and autonomous
fleet system mutation is policy-disabled.

## Why a separate component

An unprivileged R process that systemd's polkit authorizes to restart a
**system** unit cannot append to the root-owned system sink. A privileged
writer must do it on the caller's behalf. That writer is **not** the apt
boundary's `pkexec` helper:

- the apt helper performs an *authorized mutation* (installs, removes);
- the audit broker only *appends validated records*.

Merging them enlarges both privilege surfaces, and the apt helper's `pkexec`
password prompt would undermine autonomous systemd operation (an agent
restarting a service must not be forced through a prompt just to record the
audit). The broker is small, single-purpose, non-interactive, and has **no
authority to mutate anything**.

## journald first — but expect only a weaker broker

Evaluate journald before building a bespoke writer, because it is already
present, root-owned, and credential-stamped. Expect it to qualify only as a
**weaker** broker, because it does not meet the `audit_persisted` invariant
(`audit_persisted = TRUE` means the record is on stable storage and fsync
returned success):

- **Submission is not durable persistence.** A successful `sd_journal_send`
  means the record was accepted/queued, not that it is fsync'd to disk.
- **Deferred sync.** journald flushes on `SyncIntervalSec` (default minutes)
  or under storage pressure, so a crash can lose recently accepted records.
- **Retention and rate limiting drop records.** `SystemMaxUse`/vacuuming and
  `RateLimitIntervalSec`/`RateLimitBurst` can discard records under load or
  pressure, exactly when an audit trail matters most.

Conclusion: journald may serve as a **secondary/forwarding** sink or where the
weaker guarantee is explicitly accepted and advertised as such (its own
`audit_scope`/durability level), but it **cannot** back
`system_durable_audit = TRUE`. The strong path is the purpose-built broker.

## Strong broker: requirements

1. **Socket activation, not an always-resident daemon.** A systemd
   socket-activated unit: the broker starts on connection and exits when idle,
   minimizing resident privileged surface (a deliberate contrast with rapt's
   always-on daemon).
2. **Fixed, broker-owned sink path.** The broker writes only its configured
   system sink; a caller-supplied destination path is rejected. The caller
   never chooses where root writes.
3. **`SO_PEERCRED` identity, never payload identity.** The actor (uid/gid/pid)
   comes from the connected peer's kernel-verified credentials; any actor
   field in the payload is ignored and overwritten. A caller cannot claim to
   be someone else.
4. **Broker-minted correlation IDs for intents.** The broker mints the
   `correlation_id` when it accepts an intent and returns it to the caller; a
   caller cannot forge, choose, or collide IDs. The caller uses the returned
   id for its outcome and its result.
5. **Outcome writes bound to the original actor and intent.** An outcome for
   id X is accepted only from the same `SO_PEERCRED` actor that opened intent
   X, and only for an intent the broker actually recorded. No one can close or
   fabricate another principal's operation.
6. **Strict framing, schema, and size validation.** Requests are explicitly
   framed (length-prefixed); each record is validated against the durable-audit
   schema and a size cap before any write. Malformed or oversize requests are
   rejected, not written.
7. **Rate limits and quotas.** Per-actor rate limits and total quotas resist
   log-filling attacks (an unprivileged caller flooding the root sink to
   exhaust disk or drown real records). Rejection is explicit and itself
   auditable in aggregate.
8. **Atomic append and fsync via the hardened sink.** The broker performs the
   actual write through the runix hardened file sink: whole-line `O_APPEND`,
   advisory lock, file fsync, parent-directory fsync on create/rotation,
   honest failure reporting. It reuses that machinery rather than
   reimplementing it.
9. **Crash-gap preservation.** An intent with no matching outcome stays on
   disk as a queryable open operation (a crash between issue and confirm is a
   diagnostic signal, not a hole). The broker never garbage-collects open
   intents.
10. **No mutation authority.** The broker only validates and appends audit
    records. It never runs `systemctl`, `apt`, or any other effect, and holds
    no capability beyond writing its sink.

## Record lifecycle through the broker

The broker path is a request/response protocol, not a drop-in file sink:

1. **Open intent.** Caller sends the intent's domain content. The broker
   derives the actor (req. 3), mints the `correlation_id` (req. 4), validates
   (req. 6), rate-checks (req. 7), and appends the intent durably (req. 8),
   then returns the id. **Fail-closed:** if the intent cannot be persisted,
   the broker returns failure and the mutation must not issue any effect.
2. **Issue effect.** Caller side, unchanged.
3. **Write outcome.** Caller sends the outcome content with the returned id.
   The broker verifies the id exists and its intent actor matches this peer
   (req. 5), validates, and appends the outcome durably.

**Integration note.** Because the broker mints the id (req. 4), the broker
path does not fit `audit_two_phase`'s current cid-first, locally-minted flow
unchanged: it needs a broker-backed adapter whose "open intent" call returns
the id, or an `id_fn` sourced from the broker. That adapter is specified when
the broker is built; the two-phase discipline and record schema are otherwise
identical to the file sink.

## Relationship to the rest

- Consumes the durable-audit record schema and two-phase discipline
  (`durable-audit-contract.md`) and writes through the hardened runix sink.
- Its presence flips `system_durable_audit` to `TRUE` in `rctl capabilities`
  (`rctl-json-contract.md`), which is the fleet-policy gate for autonomous
  system-scope mutation. Absent it, that stays `FALSE` and mutations record
  caller-owned.
- Entirely separate from the apt mutation boundary; the two privileged paths
  never merge.

## Conformance tests

Against a test harness that connects over the socket with controlled peer
credentials:

1. Actor is taken from `SO_PEERCRED`; a payload-supplied actor is ignored.
2. A caller-supplied sink path is rejected; the broker writes only its own
   path.
3. The broker mints the intent id; two intents never collide; a caller cannot
   dictate the id.
4. An outcome for id X from a different actor than opened X is rejected.
5. Malformed, unframed, or oversize requests are rejected before any write.
6. Rate limit / quota: a flood is throttled or rejected, and the sink is not
   exhausted.
7. An unpersistable intent returns failure and (in the driving mutation) no
   effect is issued.
8. An intent with no outcome remains on disk as an open operation.
9. The broker exposes no path that performs a mutation.
10. With the broker present, `rctl capabilities` reports
    `system_durable_audit = TRUE`; absent, `FALSE`.
