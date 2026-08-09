# Audit broker contract

Status: contract (pre-implementation; wire protocol pinned). The strong
resolution of the durable-audit authority matrix
(`durable-audit-contract.md`): the privileged,
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
3. **`SO_PEERCRED` identity, never payload identity.** The actor comes from
   the connected peer's kernel-verified credentials; any actor field in the
   payload is ignored and overwritten. The **full** identity is persisted and
   matched, not UID alone: `uid`, `gid`, `pid`, plus the boot id and the
   peer's process start time, so a reused PID (or a post-reboot PID
   collision) cannot impersonate the original opener. Weakening this to
   UID-only would require an explicit contract + threat-model amendment; it is
   not a silent default.
4. **Broker-minted correlation IDs for intents.** The broker mints the
   `correlation_id` when it accepts an intent and returns it to the caller; a
   caller cannot forge, choose, or collide IDs. The caller uses the returned
   id for its outcome and its result.
5. **Outcome writes bound to the original actor and intent.** An outcome for
   id X is accepted only from a peer whose **full** identity (uid/gid/pid +
   boot id + process start time) matches the one that opened intent X, and
   only for an intent the broker actually recorded and that is still open. No
   one can close or fabricate another principal's operation, and a leaked
   binding is useless to any other peer because the kernel-verified identity
   must still match.
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

**Integration note.** The runix sink interface is now the receipt-based
lifecycle (`open_intent(record) -> receipt`, `write_outcome(receipt, record)`;
`durable-audit-contract.md`), and `audit_two_phase` mints the id via the
sink. So the broker slots in as **another sink implementation**: an R
`AF_UNIX` client whose `open_intent` sends the request and returns the
broker-minted id in the receipt (with the opaque `binding`), and whose
`write_outcome` sends the outcome with that receipt. No changes to
`audit_two_phase` or the consumers; only the sink differs.

**The R client parses responses too.** The broker is not the only parse
boundary: the R adapter parses the broker's response frames (with yyjsonr,
not jansson). The response is trusted local IPC, but the adapter must still
enforce the same frame limits (version, hard length cap) and an **exact
response schema** (known fields, correct types), and fail closed on anything
else. Because the two sides use different JSON libraries, the protection is
**cross-library conformance tests**: shared fixtures (valid and malformed
frames, edge-case records) run through both the jansson broker and the
yyjsonr adapter, asserting identical accept/reject decisions. A shared
implementation is explicitly not the mechanism.

## Wire protocol (pinned before implementation)

The protocol is small, versioned, and rigid. It is fixed here so the C build
implements a spec rather than inventing one.

- **Framing.** Every message is a fixed header plus a body: a protocol
  **version** byte and a big-endian **`uint32` length** prefix for the body,
  which carries a **hard maximum** (e.g. 64 KiB). A length that is malformed,
  exceeds the maximum, or does not match the bytes received is a typed error
  and the connection is closed. Versioning lets the broker reject an
  unsupported client rather than guess.
- **Body: strict UTF-8 JSON**, parsed by **Jansson** (the system,
  apt-serviced library) with `JSON_REJECT_DUPLICATES` (native duplicate-key
  rejection), strict EOF (reject trailing content), `JSON_VALIDATE_UTF8`, and
  a bounded parse depth. **No hand-written parser** (the parser is the largest
  attack surface; do not build one). Jansson is chosen over json-c
  specifically because json-c 0.17 cannot reject duplicate keys (it silently
  keeps last-wins); both are apt-serviced from Ubuntu main, so the supply-chain
  posture is unchanged. yyjson would require vendoring (no system package) and
  a janssonr R package was rejected: the C broker and the R stack interoperate
  through this wire schema, not a shared library.
- **Two request types only:** `open_intent` and `write_outcome`. Any other
  type is a typed `unknown_request` error. There is no general command
  channel.
- **`SO_PEERCRED` overrides all payload identity.** The full actor identity
  (uid/gid/pid + boot id + process start time) comes from the kernel-verified
  peer credentials; any identity field in the body is ignored and
  overwritten. A client cannot claim to be another principal.
- **The receipt `binding` authorizes exactly one narrowly-scoped action:**
  appending the outcome for *its own* intent, and only from a peer whose full
  identity matches the opener. It cannot authorize a mutation, a different
  intent, or any other broker operation, and possession alone is insufficient
  (the peer-identity check is load-bearing). It is **sensitive**: the broker
  stores it raw only because the sink is root-privileged and actor-matching
  is the real gate; it is marked sensitive and excluded from any
  forwarding/export view of the audit trail.
- **Deterministic responses, typed protocol errors.** Each request yields
  exactly one framed response of a fixed shape. Errors are a closed, typed
  set (e.g. `bad_frame`, `too_large`, `bad_json`, `unknown_request`,
  `schema_invalid`, `unknown_intent`, `actor_mismatch`, `rate_limited`,
  `persist_failed`); the same input always yields the same response class.
- **Disconnects never erase a durable intent.** Once `open_intent` has fsync'd
  the intent and returned the receipt, the intent stands regardless of what
  happens to the connection. A disconnect between intent and outcome leaves an
  open intent (a queryable crash-gap), never a rollback.

## Broker I/O and packaging

- **Descriptor-based, hijack-safe writes.** Open the sink once with
  `O_APPEND | O_NOFOLLOW | O_CLOEXEC` and hold the descriptor; never reopen by
  path per write. `O_NOFOLLOW` refuses a symlinked sink at open; `O_APPEND`
  gives atomic positioning.
- **Advisory locking** (`flock(LOCK_EX)`) around the append+fsync critical
  section, since a full JSONL line can exceed `PIPE_BUF`.
- **Complete-write loops.** `write(2)` may write partially; loop until the
  whole line is written, handling `EINTR`/`EAGAIN`. No assumption that one
  `write` emits the whole record.
- **`fdatasync` the file** after the append, and **fsync the parent
  directory** after a create or rotation, before reporting `persisted`.
- **Packaging.** A systemd **socket unit** (`runix-audit-broker.socket`) and a
  socket-activated **service unit** with strong sandboxing:
  `NoNewPrivileges`, `ProtectSystem=strict` with `ReadWritePaths=` limited to
  the sink directory, `ProtectHome`, `PrivateTmp`, `RestrictAddressFamilies=AF_UNIX`,
  a minimal `CapabilityBoundingSet`, a `SystemCallFilter` allowlist, and
  `MemoryDenyWriteExecute`. The **production sink path is fixed** in the
  service configuration; a **test-path override is process configuration**
  (env/CLI/config to the broker process), **never a protocol input** — a
  client can never tell the broker where to write.

## Durable state, reconstruction, and rotation

The broker holds **no authoritative in-memory state**: the sink is the single
source of truth, and any in-memory map (open intents, per-actor rate counters)
is a cache rebuilt from it. This is what makes socket activation and restart
safe.

- **Persisted per intent:** the broker-written intent record carries the
  correlation id, the **full peer identity** (uid/gid/pid + boot id + process
  start time), and the binding. An open intent is one whose correlation id has
  an intent record but no outcome record.
- **Startup reconstruction:** scan the current segment (and its retained tail)
  to rebuild the open-intent set and the per-actor rate state. Rate windows
  are rebuilt from **broker-assigned** record timestamps, never caller-
  supplied times.
- **Reconstruction fails closed.** Reject and refuse to serve on: an outcome
  with no matching intent, a second outcome for an already-closed intent, or
  inconsistent duplicate intents. A torn final line (partial-tail from a crash
  mid-append) is recovered by discarding exactly that trailing partial record;
  any other unexplained corruption is fatal, not silently skipped.
- **Rotation is carry-forward, never refusal.** Refusing to rotate while an
  intent is open would be a trivial disk-exhaustion attack (hold one intent
  open forever, block rotation). Instead, open intents are **checkpointed**
  into the new segment:
  - open intents are bounded **per-uid and globally**; opening beyond the cap
    is a typed `rate_limited`/`too_many` error, not unbounded growth;
  - a carry-forward record is an explicit checkpoint (a distinct `phase`), not
    an ambiguous second `intent`, and duplicate carry-forwards are
    **idempotent** on reconstruction (same correlation id collapses to one
    open intent);
  - the new segment is written and its data **and parent directory fsync'd
    before the old segment is retired**, so a crash during rotation never
    loses an open intent.

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

Protocol and abuse tests (a lying or hostile client):

11. **Malformed length** — a length prefix that lies (too small, too large,
    or truncated relative to the bytes sent) is rejected, nothing written.
12. **Oversized frame** — a body over the hard maximum is rejected before any
    parse or write.
13. **Invalid UTF-8** — a body that is not valid UTF-8 is rejected by the
    parser, nothing written.
14. **Schema confusion** — valid JSON of the wrong shape (missing/extra
    fields, wrong types, a `write_outcome` shaped like an `open_intent`) is
    rejected with `schema_invalid`.
15. **Forged identity** — a payload claiming a different uid than
    `SO_PEERCRED` is recorded under the `SO_PEERCRED` actor, not the claim.
16. **Replayed receipt** — reusing a receipt/binding to close a different or
    already-closed intent is rejected (`unknown_intent`/`actor_mismatch`),
    with no duplicate or misattributed outcome.
17. **Concurrent writers** — many clients interleaving produce only whole,
    parseable lines, each outcome bound to its own intent.
18. **Broker restart** — with socket activation, the broker exiting and
    restarting loses no durable intent and serves new connections; open
    intents from before the restart remain queryable.
19. **Disconnect after intent** — a client that drops right after
    `open_intent` returns leaves the intent durable and open, never erased.
20. **Client-side response validation** — the R adapter rejects a response
    frame that violates the version/length limits or the exact response
    schema, and fails closed rather than trusting a malformed reply.
21. **Cross-library conformance** — shared fixtures (valid and malformed
    frames, edge-case records) produce identical accept/reject decisions
    through the jansson broker and the yyjsonr adapter; the two independent
    parsers agree on the wire schema.

Durable-state reconstruction and rotation:

22. **Reconstruction fails closed** — a sink containing an outcome with no
    matching intent, a double outcome, or an inconsistent duplicate intent is
    rejected at startup, not silently served.
23. **Partial-tail recovery** — a torn final line (crash mid-append) is
    discarded and every earlier record remains intact and usable; any other
    corruption is fatal.
24. **Carry-forward idempotency** — rotation with an open intent checkpoints
    it into the new segment; reconstruction collapses duplicate carry-forwards
    to a single open intent, which is still closable afterward.
25. **Bounded open intents** — opening beyond the per-uid or global cap is
    rejected (`too_many`/`rate_limited`); rotation is never refused, so an
    open intent cannot be used to exhaust disk.
26. **Full-identity match** — an outcome from the same uid but a different pid
    or process start time (PID reuse) is rejected (`actor_mismatch`), not
    accepted as the original opener.
27. **Rate limits survive restart** — counters rebuilt from broker-assigned
    timestamps are not reset by a restart, so idle-exit + reconnect does not
    bypass the limit.
