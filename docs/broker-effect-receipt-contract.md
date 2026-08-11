# broker effect-receipt contract

Status: contract (pre-implementation). The **first unit** of the apt-mutation
arc: a new `runix-audit-broker` capability the privileged helper needs before it
may commit a package transaction. Sequenced ahead of the `libapt-pkg` helper and
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

## Delegated identity: the redeemer is root, not the caller

The helper redeems as **root** (uid 0), so the broker **must not** require
redeemer `SO_PEERCRED` == issuing caller. Instead:

- The receipt is a broker-issued token backed by durable broker state; the broker
  authenticates it by **looking it up in that state** (as it already matches a
  `binding`), not by who presents it.
- The issuing caller's verified identity is **bound into the receipt at issue**
  (from the unprivileged `SO_PEERCRED`) and recorded, so "who intended this" is on
  the durable record even though root redeems it. This is delegated auditing with
  a verified original identity.
- Redemption authorizes committing **this exact operation**: the helper's
  presented `verb`, `resource`, and `plan_hash` must equal the bound values.
  Matching, unexpired, unredeemed → `ok`; anything else → typed refusal.

## Plan hash

`plan_hash` is the hash of a **canonical plan representation** both sides compute
identically: the sorted set of `(package, action, target-version)` tuples of the
whole resolved transaction (target and every pulled dependency), plus purge/hold
flags — never a rendered CLI string. The unprivileged preview (apt simulate /
introspection) yields the issue-time hash; the helper's atomic `libapt-pkg`
resolve yields the redeem-time hash. Equality is the TOCTOU/drift gate: a plan
that changed between preview and atomic resolve does not redeem. The canonical
form is pinned in a shared spec so R and the C helper hash the same bytes.

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

## Single use, TTL, replay, restart

- **Single use.** A second `redeem_receipt` for a receipt already redeemed is
  refused (`receipt_redeemed`); a replayed receipt cannot authorize a second
  commit.
- **TTL.** Receipts carry a short TTL bound at issue (broker-assigned time, never
  client input). A redemption past it is refused (`receipt_expired`); an
  un-redeemed receipt simply expires and its intent stays open.
- **Restart.** Receipt state is part of the durable intent state the broker
  reconstructs from the current segment (and carries across rotation as a
  checkpoint), so a redeemed receipt stays redeemed and an unexpired one stays
  redeemable across a restart. Replay-proofing survives a bounce.

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

// redeem_receipt (from the helper, before commit)  — NEW request type
{ "type": "redeem_receipt",
  "effect_receipt": "<opaque>",
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
| `receipt_expired` | past its TTL |
| `receipt_redeemed` | already redeemed (single-use) |
| `receipt_mismatch` | verb/resource/`plan_hash` differ from the bound values |

`unknown_request` still covers a type that is not one of the now-four verbs. The
`effect` object is bounded and typed like any other input; `plan_hash` is a
fixed-width hex string.

## Schema and version

- Bump the broker `schema_version`; effect-receipt fields are new. A client that
  sends no `effect` gets exactly today's behaviour (older clients unaffected).
- The receipt fields are **broker state and record framing**, not client-set
  record content: `plan_hash` and the bound identity are stamped/derived by the
  broker; the record schema's fixed allowlist (`json.c` `RECORD_SCHEMA`) is
  unchanged for domain content.

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

## Out of scope here

The `request_id`/`reconciles` schema extension for deferred unattended
resume-by-id and written reconciliation records (`apt-mutation-boundary-contract.md`,
"Broker schema dependency") is a separate broker change; this contract is only
the effect-receipt capability that v1 requires.
