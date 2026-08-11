# broker effect-receipt contract

Status: contract (pre-implementation), **revised after review** (2026-08-11).
The **first unit** of the apt-mutation arc: a new `runix-audit-broker` capability
the privileged helper needs before it may commit a package transaction.

**This revision adds:** a hardened redemption gate (uid-0 redeemer, `PKEXEC_UID`
matched to the bound actor, private-pipe token transfer, verifier-hash
persistence); at-most-once commit semantics under a lost response; a fully pinned
plan digest with per-verb descriptors; an explicit receipt state machine
(monotonic TTL, boot-id invalidation, rotation/restart recovery) and an
effect-outcome-requires-redemption invariant; and a three-axis versioning model
that leaves the public record schema unchanged. Sequenced ahead of the `libapt-pkg` helper and
`pkgops` (see `apt-mutation-boundary-contract.md` "Verification ladder"); the
helper is not started until this lands and is conformance-tested. Builds on
`audit-broker-contract.md` and `PROTOCOL.md` (the broker's wire protocol and
durable open-intent state).

## What it guarantees

The apt boundary requires **no host effect without a durable, matching intent**,
enforced at the privileged boundary rather than trusted to bypassable R code
(`apt-mutation-boundary-contract.md`). The **effect receipt** is that
enforcement: the helper redeems a broker-issued receipt *before* it commits, and
refuses (`runix_no_intent`) if there is none valid. Two properties fall out:

1. **Audit completeness.** Every committed transaction has a durable intent on
   disk, recorded *before* the effect — the helper cannot mutate the system with
   no record, even if invoked directly.
2. **Plan binding across the privilege boundary.** The receipt carries the hash
   of the plan the unprivileged side previewed; at redemption the broker checks
   it against the plan the helper's atomic `libapt-pkg` resolve produced. If they
   differ — state drifted between preview and resolve — redemption fails and the
   effect never runs. The approved plan is provably the committed plan.

## Threat model (what it is and is not)

The receipt makes the **trusted helper path** refuse to act without a durable,
plan-matching intent. It is **not** a defense against a root attacker: root can
already do anything and does not need the helper. Its job is integrity and
completeness of the audit trail, and binding the committed plan to the previewed
one, within an already-root-trusted effect path — not to constrain root itself.

## Distinct from the outcome `binding`

The broker already issues, at `open_intent`, an opaque single-use `binding` that
authorizes exactly one `write_outcome` for that intent, redeemed **after** the
effect by the **unprivileged caller** (`PROTOCOL.md`, "The receipt binding"). The
effect receipt is a **separate** token with a different redeemer, time, and
purpose:

| | outcome `binding` | effect receipt |
|---|---|---|
| issued at | `open_intent` | `open_intent` (when an effect is requested) |
| redeemed by | the unprivileged caller | the **root** helper (`pkexec`'d) |
| redeemed when | **after** the effect (to append the outcome) | **before** the effect (to authorize committing) |
| binds | intent + caller identity | intent + caller identity + verb + resource + preview-plan hash |
| lifetime | until the outcome is written | short TTL |

Both are 128-bit CSPRNG tokens backed by the intent's durable state, single-use,
and survive a restart; they are independent (redeeming one never affects the
other).

## Lifecycle

```
unprivileged R                     broker                    root helper (pkexec)
   |-- open_intent (+effect req) ---->|  mint receipt, bind
   |<-- correlation_id, binding, ----|  {cid, caller id, verb,
   |    effect_receipt                |   resource, plan_hash}, fsync
   |-- receipt --------------------------------------------->|
   |                                  |<-- redeem_receipt (+ helper's
   |                                  |    verb/resource/plan_hash) --|
   |                                  |  verify + mark redeemed, fsync
   |                                  |--- ok ---------------------->|
   |                                  |                   commit (libapt)
   |<-- (effect result) --------------------------------------------|
   |-- write_outcome (binding) ------>|  append outcome, fsync
   |<-- ok ---------------------------|
```

- **Issue.** `open_intent` gains an optional `effect` request. When present, the
  broker mints an effect receipt bound to the intent's `correlation_id`, the
  **issuing caller's full `SO_PEERCRED` identity**, the record's `operation`
  (verb) and `resource`, and a caller-supplied **`plan_hash`** (the hash of the
  unprivileged preview plan). The receipt is made durable (fsynced) as part of
  the intent, *before* the reply, and returned alongside `binding`.
- **Transfer.** The unprivileged R passes the receipt to the helper over the
  helper's narrow protocol (an argument, not the environment).
- **Redeem (before commit).** The helper sends `redeem_receipt` carrying the
  receipt and the `verb`, `resource`, and `plan_hash` of the transaction its
  atomic `libapt-pkg` resolve produced. The broker verifies (below), marks the
  receipt **redeemed durably (fsynced) before replying `ok`**, and only then does
  the helper commit. A failure is fail-closed: the helper does not commit.
- **Outcome.** After committing, the unprivileged R writes the outcome with the
  `binding`, unchanged from today.

## Delegated identity: root redeemer, verified against the original actor

The helper redeems as **root** (`pkexec`'d), so redeemer `SO_PEERCRED` is uid 0,
not the issuing caller. Redemption is gated by three checks, never by
`redeemer == caller`:

- **The redeemer must be uid 0.** The broker requires the redeeming peer's
  kernel-verified `SO_PEERCRED` uid to be `0`; a non-root redeemer is refused
  (`receipt_unauthorized`). Only the privileged helper redeems.
- **The original principal must match the bound actor.** `pkexec` exports the
  invoking uid as `PKEXEC_UID`; the helper reads it from the trusted `pkexec`
  environment (not caller-controlled) and presents it in `redeem_receipt`. The
  broker requires it to equal the uid bound into the receipt at issue — pinning
  the delegation chain to *a root helper invoked by the same principal that opened
  the intent*. A mismatch is refused (`receipt_actor_mismatch`).
- **Operation match** (below): verb, resource, and `plan_hash` equal the bound
  values.

The receipt is still authenticated by the broker's durable state (as a `binding`
already is), not by who presents it — but two rules keep the token from leaking:

- **Transfer over a private channel.** The unprivileged R passes the receipt to
  the helper via **stdin / a private pipe**, never `argv` or the environment —
  both are observable (`/proc/<pid>/cmdline`, `/proc/<pid>/environ`, `ps`).
- **Persist a verifier, not the token.** The broker's durable state stores only a
  **hash** of the receipt token (a verifier), never the live token; redemption
  hashes the presented token and compares. A reader of the sink or state cannot
  recover a usable receipt.

The issuing caller's verified identity is bound into the receipt at issue (from
the unprivileged `SO_PEERCRED`) and on the durable record, so "who intended this"
is recorded even though root redeems it — delegated auditing with a verified
original identity.

## Plan digest

`plan_hash` must be reproducible byte-for-byte on both sides, so it is fully
pinned — not left to "hash the plan":

- **Algorithm:** SHA-256 over a canonical UTF-8 byte encoding; the lowercase hex
  digest is the `plan_hash`.
- **Digest schema version.** The canonical encoding carries its own version,
  independent of the wire and record schemas; a change to the descriptor format
  bumps it, and issue and redeem must use the same version.
- **Per-verb descriptor.** A package-tuple set only fits install/remove-style
  transactions, so each verb has a defined descriptor:
  - `apt.install`/`remove`/`purge`/`upgrade`/`dist_upgrade`: the sorted set of
    `(package, architecture, action, from-version, to-version, flags)` over the
    **whole resolved transaction** — target and every pulled dependency — where
    `action ∈ {install, upgrade, downgrade, remove, purge}` and `flags` captures
    hold/auto/essential markers.
  - `apt.configure`: the sorted set of `(package, architecture)` pending
    configuration.
  - `apt.hold`/`apt.unhold`: the sorted set of `(package, from-hold-state,
    to-hold-state)`.
  - `apt.update`: no package transaction — the descriptor is the sorted set of
    source entries `(uri, suite, components)` to be refreshed.
- **Canonical encoding:** fields in a fixed order, tuples sorted, explicit
  separators, versions as exact strings (never locale-formatted), and a stable
  empty representation. Pinned in a shared spec both the R side and the C helper
  build against, with shared test vectors.

The unprivileged preview yields the issue-time digest; the helper's atomic
`libapt-pkg` resolve yields the redeem-time digest. Equality is the TOCTOU/drift
gate: a plan that changed between preview and atomic resolve does not redeem.

## Durability, ordering, and crash cases

Ordering is the whole point, so it is stated exactly:

- **Issue** is durable (fsynced) before `open_intent` replies, like any intent.
- **Redemption** is durable (fsynced) before the broker replies `ok`, so the
  helper only commits after "redeemed" is on disk.

The crash cases map onto the existing open-intent reconciliation
(`apt-mutation-boundary-contract.md`, "Partial failure and recovery"):

- broker crashes after issue, before redeem → an open, un-redeemed intent; the
  effect never ran; reconciliation finds no dpkg change.
- broker crashes after marking redeemed, before the helper commits → redeemed,
  no outcome, no dpkg change → reconciliation resolves it as not-applied.
- helper commits, then dies before `write_outcome` → redeemed, no outcome, dpkg
  changed → the interrupted-transaction case, reconciled against dpkg ground
  truth.

In every case the durable record is honest and reconcilable; the effect is never
assumed from the receipt's existence.

## Commit safety: at-most-once under a lost response

Redemption is fsynced **before** the broker replies, so a receipt can be spent on
disk while the `redeem_ok` reply is lost (disconnect, timeout). The helper's rule
is therefore strict: **commit only after receiving a valid `redeem_ok`.**

- Timeout, disconnect, or a `receipt_redeemed` ("already redeemed") reply → the
  helper does **not** commit. The operation is redone fresh (new intent + new
  receipt) or left to reconciliation.
- Because redemption is single-use and durable-before-reply, a lost reply can
  never yield a second commit: the spent receipt cannot be redeemed again, and a
  helper that never saw `redeem_ok` never committed. The failure mode is
  **at-most-once**, biased to *not applied* — a redeemed-but-uncommitted receipt
  leaves a redeemed-no-outcome intent that reconciliation resolves as not applied
  (no dpkg change).

This is exactly why redemption is a distinct round trip *before* commit, not
folded into it: the durable "redeemed" marker is what makes the lost-response case
safe.

## Receipt state machine and persistence

A receipt is exactly one of **issued → redeemed** or **issued → expired**;
redeemed and expired are terminal. There is no un-redeem.

- **Transitions.** `issue` writes an *issued* receipt (verifier hash, bound
  fields, TTL, boot id), durable before the `open_intent` reply. `redeem` moves
  *issued → redeemed*, durable before the `ok` reply. A redeem of a redeemed
  receipt is `receipt_redeemed`; of an expired one, `receipt_expired`.
- **Single use.** A second `redeem_receipt` for a redeemed receipt is refused, so
  a replayed receipt cannot authorize a second commit.
- **TTL is same-boot monotonic.** The TTL is measured on `CLOCK_MONOTONIC` from a
  broker-assigned issue time, never client input. A receipt also records the
  **boot id**; on a **boot-id change** every outstanding receipt is invalid
  regardless of wall-clock — monotonic time resets across a reboot, so a
  cross-reboot TTL is meaningless. A redeem whose boot id differs from the
  broker's current boot id is refused (`receipt_expired`).
- **Rotation carry-forward.** Issued, unexpired receipts are re-materialised into
  the fresh segment on rotation, alongside the open-intent checkpoints, so the
  current segment stays the authoritative superset.
- **Daemon-restart recovery.** Reconstruction reads the current segment and
  rebuilds receipt state with the same strict, fail-closed validation as records;
  a redeemed receipt stays redeemed (replay-proof across a restart), an issued one
  stays redeemable only while its boot id still matches.
- **Host reboot.** After a reboot the boot id differs, so no pre-reboot receipt is
  redeemable; their intents are open, un-redeemed, and reconcilable. A receipt can
  never straddle a reboot.

**Effect outcomes require a redemption.** A `write_outcome` carrying
`effect_issued: true` is refused (`effect_without_receipt`) unless the intent's
effect receipt was redeemed. This closes "commit with no redemption" from the
outcome side too: an effect can only be recorded as issued if the broker durably
authorized it.

## Wire protocol additions

Extends `PROTOCOL.md` (still one request frame → one response frame):

```jsonc
// open_intent, requesting an effect receipt
{ "type": "open_intent",
  "record": { "operation": "apt.install", "resource": "nginx", ... },
  "effect": { "plan_hash": "<hex>" } }        // NEW, optional

// open_intent response now may carry the receipt
{ "ok": true, "correlation_id": "...", "binding": "...",
  "effect_receipt": "<opaque>", "persisted": true, "audit_scope": "system" }

// redeem_receipt (from the ROOT helper, before commit)  — NEW request type
{ "type": "redeem_receipt",
  "effect_receipt": "<opaque>",              // carried over the private socket,
                                             //   never argv/env (R->helper uses stdin)
  "principal_uid": 1000,                     // original invoking uid, from PKEXEC_UID
  "effect": { "operation": "apt.install", "resource": "nginx",
              "plan_hash": "<hex>" } }

// redeem_receipt response
{ "ok": true, "correlation_id": "...", "persisted": true }
```

New closed-set error codes (the R/helper adapters reject any code outside the
set, so each is a two-sided contract change):

| code | meaning |
|---|---|
| `receipt_invalid` | no such effect receipt (unknown / malformed) |
| `receipt_expired` | past its TTL, or the boot id changed |
| `receipt_redeemed` | already redeemed (single-use) |
| `receipt_mismatch` | verb/resource/`plan_hash` differ from the bound values |
| `receipt_unauthorized` | the redeeming peer is not uid 0 |
| `receipt_actor_mismatch` | `principal_uid` differs from the bound original actor |
| `effect_without_receipt` | a `write_outcome` with `effect_issued: true` whose receipt was never redeemed |

`unknown_request` still covers a type that is not one of the now-four verbs. The
`effect` object is bounded and typed like any other input; `plan_hash` is a
fixed-width hex string.

## Versioning

Three independent version axes; this change touches only some, and existing
clients stay compatible:

- **Frame-protocol version** (the 1-byte frame `version`, `PROTOCOL.md`):
  **unchanged** — framing is identical.
- **Public audit-record schema** (`schema_version` in records, `RECORD_SCHEMA`):
  **unchanged.** Effect-receipt data is request/response and broker state, not
  record content, so `RECORD_SCHEMA`'s fixed allowlist is untouched and a client
  using the exact record schema is byte-for-byte unaffected. `schema_version`
  bumps only if a *record field* is added, which this capability does not need.
- **Private broker-extension version** (new): the effect-receipt capability — the
  `effect` request member, the `effect_receipt` response member, the
  `redeem_receipt` verb, and the new error codes — is advertised under a broker
  extension/capability version, so a client can learn whether receipts are
  supported. A broker without it never issues receipts; a client that sends no
  `effect` gets exactly today's behaviour.
- **Plan-digest schema version** (above): independent of all of these; issue and
  redeem must agree on it.

Net: today's `open_intent`/`write_outcome`/`emit` callers and exact-schema record
readers are unaffected; the capability is purely additive and negotiated.

## Shared response-fixture corpus

The issue/redeem request and response shapes, their byte-exact goldens, and the
refusal frames join the single shared corpus
(`inst/tinytest/fixtures/broker-frames/`, vendored into the broker repo), so the
R adapter and the C broker test against one source of truth, exactly as the
existing frames do.

## Conformance tests (broker side)

1. Issue: `open_intent` with an `effect` returns a distinct `effect_receipt`
   (≠ `binding`), durable before the reply.
2. Redeem happy path: a matching, unexpired, unredeemed receipt redeems `ok`,
   fsynced before the reply.
3. Delegated identity: redemption succeeds when the redeemer's `SO_PEERCRED`
   (root) differs from the issuing caller's; the bound caller identity is on the
   durable record.
4. Plan mismatch: a `plan_hash` (or verb/resource) differing from the bound value
   is refused `receipt_mismatch`; no redemption is recorded.
5. Single use: a second redemption of the same receipt is refused
   `receipt_redeemed`.
6. TTL: redemption past the bound TTL is refused `receipt_expired`.
7. Restart: a redeemed receipt stays redeemed, and an unexpired one stays
   redeemable, across a broker restart (reconstruction + rotation checkpoint).
8. Independence: redeeming the effect receipt does not consume the outcome
   `binding`, and vice versa.
9. Ordering: redemption is not visible as durable until fsynced; a crash between
   mark-redeemed and reply leaves a reconcilable redeemed-no-outcome intent.
10. Unprivileged redemption: a redeemer whose `SO_PEERCRED` uid is not 0 is
    refused `receipt_unauthorized`; no redemption is recorded.
11. Delegated-actor mismatch: a `principal_uid` differing from the bound original
    actor is refused `receipt_actor_mismatch`, even from a uid-0 redeemer.
12. Token non-disclosure: the live receipt token never appears in `argv`, the
    environment, or any exported/forwarded record; durable state holds only the
    verifier hash, and a state reader cannot reconstruct a redeemable token.
13. Effect outcome without redemption: a `write_outcome` with
    `effect_issued: true` whose intent's receipt was never redeemed is refused
    `effect_without_receipt`.
14. Disconnect after fsync: the broker fsyncs the redemption, then the connection
    drops before the reply; the receipt is spent (a retry gets `receipt_redeemed`)
    and a helper that never saw `redeem_ok` does not commit — at-most-once,
    reconciled as not applied.

## Out of scope here

The `request_id`/`reconciles` schema extension for deferred unattended
resume-by-id and written reconciliation records (`apt-mutation-boundary-contract.md`,
"Broker schema dependency") is a separate broker change; this contract is only
the effect-receipt capability that v1 requires.
