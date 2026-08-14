# pkgops: the unprivileged apt-mutation issuer (plan)

**Status: plan only. No code until the planner boundary and the per-verb R API +
result schemas below are reviewed and signed off.** This document is the central
review artifact for the second-and-final unit of the apt-mutation arc; it spans
runix, pkgexec, runix-audit-broker, and pkgstate, and reaches rctl at the end. The
`pkgops` repo is not created until this plan is accepted.

## 1. What pkgops is, and is not

`pkgops` is the **unprivileged, R-facing** layer that turns a requested apt mutation
into a *previewed → approved → receipted → committed → verified → audited*
operation. It is the production issuer the Stage-4 VM stand-in (`rab-exercise`) was a
model of.

- **Unprivileged.** It runs as the calling (non-root) principal. It never holds the
  dpkg lock, never links `libapt-pkg` for mutation, and reaches privilege only by
  invoking a per-verb pkexec entrypoint that redeems a broker receipt.
- **Not the plan authority.** It does not re-derive the plan digest in R. The
  descriptor/resource/`plan_hash` come from a single shared implementation (§3); the
  R side only *carries* them. The **locked pkgexec re-resolution at commit stays
  authoritative**: any drift between preview and commit fails closed at redeem.
- **Owns only its half of the audit.** The broker records the durable intent and
  outcome; pkgexec issues the effect; pkgstate observes native state. pkgops
  *orchestrates* the two-phase write (open the effect-required intent, close the
  outcome) but writes no audit itself and evaluates the result, never fabricating
  one.
- **pkgstate stays read-only.** Verification reads through pkgstate; the mutation
  lives here, in a separate sibling, exactly as the arc's contract requires.

## 2. Scope of verbs

The nine contracted verbs, matching the pkexec entrypoints
(`/usr/libexec/pkgexec/runix-apt-*`):

| family | verbs | targets |
|---|---|---|
| transaction | `install`, `remove`, `purge`, `upgrade`, `dist_upgrade` | packages (upgrade/dist_upgrade take none) |
| update | `update` | none (whole source list) |
| hold | `hold`, `unhold` | packages |
| configure | `configure` | none (the pending set) |

`update` and `hold` are the two *autonomous* verbs (a member principal may run them
non-interactively); every other verb is interactive-gated. pkgops enforces nothing
about polkit itself (authorization is the broker's capability check (§4.3) plus the
kernel/polkit gate on the entrypoint), but it must **surface** the distinction so a
caller/agent can reason about it.

## 3. The preview mechanism (the planner boundary): first decision

The preview needs the *exact* schema-1 `resource` + `plan_hash` a receipt will be
bound to. Re-deriving that in R would reintroduce drift the moment apt's resolver,
the digest grammar, or the ownership predicate changed. So:

**Ship a new, unprivileged, read-only planner binary from pkgexec** (working name
`runix-apt-preview`), the *single implementation* of the preview descriptor/digest.
It is **not** the root VM diagnostic `pkgexec-plan` (which holds the dpkg lock and is
never installed), and it is **not** an authority.

- **Reuses the committer's own code.** It links the same `pkgx_apt_map_txn` (resolve
  → schema-1 record model) and `pkgx_digest_*` (canonical resource + hash) the nine
  effectors and the VM oracle use. One code path computes the digest, so a matching
  cache yields a matching hash.
- **Read-only, lockless, no mutation.** It opens the apt cache without the dpkg
  frontend lock and never calls a committer. It is safe to run as any user, any
  number of times.
- **Emits**, as strict JSON on its result channel: `plan_schema`, `resource`,
  `plan_hash`, and a *typed, human-readable preview* of the resolved transaction
  (the target plus every pulled dependency: action, from/to version, ownership and
  protection flags, held-package notes), plus advisory policy verdicts (would this be
  refused for ownership/protection/hold?).
- **Advisory only.** Its verdict never authorizes anything. The authoritative
  decision is the locked re-resolution inside the pkexec entrypoint at commit; if the
  cache moved between preview and commit, the recomputed `plan_hash` differs, the
  broker's `redeem_receipt` sees a hash mismatch, and the commit **fails closed
  (`no_intent`)** with nothing applied. Preview/commit consistency is a *binding*
  property, not a trust property.

Open sub-decisions for review (§12): the preview binary's name and result-channel
contract; whether it is one binary or a `--preview` mode on a shared core; how it
represents "the transaction is empty" (a genuine no-op vs a refusal) so the R side
never opens an intent for nothing.

## 4. The lifecycle

The pinned sequence, each step fail-closed. pkgops drives it in one R process; the
receipt lives only in that process's memory.

```
preview → approval decision → broker capability check → open effect-required intent
  → private receipt pipe to the exact pkexec entrypoint → strict result parse
  → pkgstate verification → outcome
```

### 4.1 preview
Call `runix-apt-preview` for the verb+targets. On any non-clean preview (planner
unavailable, malformed output, resolve failure, or an advisory refusal) pkgops
**stops here** and returns a typed preview error; no intent is opened.

### 4.2 approval decision (terminal)
The resolved preview is presented for an explicit approval. Approval is **terminal
and specific**: it approves *this* `{verb, resource, plan_hash}` and nothing else. An
approved decision can never be silently widened, re-pointed at a different plan, or
reused for a second commit. A caller that declines ends the operation with no side
effect. (Whether approval is an interactive callback, a pre-supplied policy token, or
an agent-supplied signed decision is a §12 decision; the invariant is that the object
committed is byte-identical to the object approved.)

### 4.3 broker capability check
Before opening an intent, confirm the broker advertises the effect-receipt capability
and that this principal is permitted the operation class. A missing capability, an
unreachable broker, or a denied class fails closed with a typed condition; nothing is
attempted against the entrypoint.

### 4.4 open effect-required intent
`open_intent(operation=verb, resource, effect={plan_schema, plan_hash})` over the
authenticated broker transport. The broker mints the durable intent and a **single-use
effect receipt** bound to `{principal, operation, resource, plan_schema, plan_hash}`
and the opener's full process identity. pkgops holds the returned `correlation_id`;
the receipt is a process-local secret from here.

### 4.5 private receipt pipe to the exact pkexec entrypoint
`pkexec /usr/libexec/pkgexec/runix-apt-<verb>` with the strict request
(`{effect_receipt, correlation_id, plan_schema, packages[], lock_timeout}`) delivered
over a **private stdin pipe**, never argv, never a file, never the environment. The
verb is fixed by the entrypoint path; pkgops must invoke the path for the exact verb
it previewed. The receipt buffer is wiped after the write.

### 4.6 strict result parse
Parse the entrypoint's one strict JSON result
(`{status, effect_issued, correlation_id, detail}`) with the strict external parser
(janssonr): exact shape, dup-key rejecting, `effect_issued` a real boolean, and
`correlation_id` (when present) equal to the one held. Map `status` to a typed runix
condition. A malformed/short/duplicate result, or a cid that does not match, is a
`runix_helper_bad_result`, treated as **effect-unknown** (the host may have been
mutated), never as success.

### 4.7 pkgstate verification
Read native ground truth through pkgstate and check it against the approved plan
(e.g. install → the packages are present at the planned versions; remove → absent;
hold → the dpkg selection reads back). Verification is **independent** of the
entrypoint's self-report: a clean `status` with a post-state that disagrees is a
verification failure, not a success.

### 4.8 outcome
Close the two-phase write: `write_outcome(correlation_id, outcome)` where `outcome`
carries the honest result: `effect_issued`, the mapped status, and the verification
verdict. **Any failure after the durable intent leaves the intent open** for
reconciliation (the redeemed-no-outcome case the VM gate proves); pkgops never
fabricates an `effect_issued:false` to tidy up.

## 5. Per-verb R API (for review)

A uniform two-call shape per verb keeps approval terminal and the committed object
identical to the approved one:

```r
p  <- pkgops::apt_install_preview(c("nginx"))   # -> pkgops_preview (advisory)
out <- pkgops::apt_install(p, approval = ...)   # commits only p's {verb,resource,hash}
```

- `apt_<verb>_preview(targets, ...)` → a `pkgops_preview` object (§6.1). Verbs with no
  targets (`update`, `dist_upgrade`, `configure`) take none.
- `apt_<verb>(preview, approval, ...)` → a `pkgops_outcome` object (§6.2). It refuses
  a preview whose `{verb, resource, plan_hash}` it did not produce, and refuses to run
  a verb against a preview for a different verb.
- A combined `apt_<verb>_run(targets, approval, ...)` convenience may wrap
  preview+commit for non-interactive callers, but is defined *in terms of* the two-call
  form so there is no second code path.

The exact argument sets (lock timeout, allow-downgrade semantics, the autonomous-verb
fast path) are part of this review.

## 6. Result schemas (for review)

Both are versioned, typed, and neutral (built on runix's result shell), so rctl and
agents consume a stable shape.

### 6.1 `pkgops_preview`
`{schema_version, verb, resource, plan_schema, plan_hash, autonomous(bool),
transaction[ {package, action, from_version, to_version, owned(bool),
protected(bool), held(bool)} ], advisory_verdict, advisory_detail}`. It is inert data;
holding one grants nothing.

### 6.2 `pkgops_outcome`
`{schema_version, correlation_id, verb, resource, plan_hash, status,
effect_issued(bool), verified(bool|NA), verify_detail, condition}`, where `status` is
the mapped runix condition name and `verified` is the independent pkgstate check
(`NA` when the effect is unknown). The intent-left-open case is representable
(`effect_issued:true/unknown`, no successful outcome).

## 7. Fail-closed matrix (the invariant)

Every *unavailable*, *malformed*, or *mismatched* step fails closed, and the failure
mode is honest about whether the host may have changed:

| step | failure | result |
|---|---|---|
| preview | planner missing / malformed / resolve fail / advisory refusal | typed preview error; **no intent opened** |
| approval | declined | no side effect |
| capability | broker down / capability absent / class denied | typed condition; **nothing invoked** |
| open_intent | transport / mint failure | typed condition; no receipt in hand |
| redeem (in helper) | hash drift, replay, actor/uid mismatch, expiry | `no_intent`; **nothing committed** |
| result parse | malformed / short / dup-key / cid mismatch | `runix_helper_bad_result`; **effect-unknown** |
| verification | post-state disagrees | verification failure (not success) |
| outcome write | after a durable intent | **intent left open**; never a fabricated false |

Receipts are **process-local** (memory only, wiped on every exit path, never logged,
never persisted). Approval is **terminal** (specific to one plan, non-escalating,
single-use).

## 8. Cross-repo boundaries

- **pkgexec**: adds the unprivileged read-only planner (§3), reusing the existing
  `pkgx_apt_map_txn` + `pkgx_digest_*`. No change to the nine committing entrypoints or
  the redeem gate. Its own reviewed slice, VM-linked as before.
- **runix-audit-broker**: no new capability; pkgops uses the existing
  `open_intent(+effect)` / `redeem` / `write_outcome` and the capability advertisement.
  Confirm the capability-check surface a client uses before opening an intent.
- **pkgstate**: the verification read (§4.7). Confirm it exposes the exact native
  post-state predicates each verb needs; add read-only accessors if a gap exists. Stays
  read-only.
- **runix**: the typed conditions for the new failure modes
  (`runix_helper_bad_result`, preview/verification/capability conditions) go through the
  shared taxonomy + retryability registry; the result objects build on the neutral
  result shell.
- **rctl**: *last*. A `pkgops`-backed `apt.*` command surface (preview/approve/run),
  advertised via `rctl capabilities`, once the R API is stable.

## 9. Verification ladder

Same discipline as pkgexec: contract (this doc) → R API + result schemas → unit tests
against fakes (a fake planner, a fake broker transport, a fake entrypoint, and pkgstate
fixtures; no root, no dpkg) → reuse of the destructive disposable-VM gate, where the
real `pkgops` replaces `rab-exercise` as the issuer and the existing §7 gates run
against it end to end. What cannot be faked (locks, maintainer scripts, interrupted
transactions, partial states) is proven only on the VM.

## 10. Open decisions for review (§12 pointers)

1. Preview binary: name, result-channel contract, one binary vs a shared-core
   `--preview`; empty-transaction (no-op) representation.
2. Approval mechanism: interactive callback vs pre-supplied policy/signed decision;
   how "terminal + specific" is enforced structurally.
3. Autonomous verbs (`update`/`hold`): a non-interactive fast path that still previews
   and still opens an intent, or a distinct entry.
4. Per-verb argument sets and the `pkgops_outcome` field set (esp. the effect-unknown
   encoding).
5. pkgstate: which post-state predicates are missing for verification.
