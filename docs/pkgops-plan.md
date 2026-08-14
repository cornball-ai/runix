# pkgops: the unprivileged apt-mutation issuer (plan)

**Status: plan only, and NOT approved. No code until the planner boundary and the
per-verb R API + result schemas below are reviewed and signed off.** This document is
the central review artifact for the second-and-final unit of the apt-mutation arc; it
spans runix, pkgexec, runix-audit-broker, and pkgstate, and reaches rctl at the end.
The `pkgops` repo is not created until this plan is accepted. It aligns with the
merged `apt-mutation-boundary-contract.md` (authorization, interactive vs machine
mode) and `libapt-pkg-helper-plan.md` (the effector boundary).

## 1. What pkgops is, and is not

`pkgops` is the **unprivileged, R-facing** layer that turns a requested apt mutation
into a *previewed → authorized → receipted → committed → verified → audited*
operation. It is the production issuer the Stage-4 VM stand-in (`rab-exercise`) was a
model of.

- **Unprivileged.** It runs as the calling (non-root) principal. It never holds the
  dpkg lock, never links `libapt-pkg` for mutation, and reaches privilege only by
  invoking a per-verb pkexec entrypoint that redeems a broker receipt.
- **Not the plan authority.** It does not re-derive the plan digest in R. The
  descriptor/resource/`plan_hash` come from a single shared implementation (§3); the
  R side only *carries* them. The **locked pkgexec re-resolution at commit stays
  authoritative**; any drift between preview and commit fails closed at redeem.
- **Not the authorization authority.** Polkit decides whether this principal may run
  the verb (§4.2). The broker advertises the effect-receipt capability and mints/
  redeems/records; it does not authorize.
- **Owns only its half of the audit.** The broker records the durable intent and
  outcome (audit actor = the real caller via `SO_PEERCRED`, never root); pkgexec
  issues the effect; pkgstate observes native state. pkgops *orchestrates* the two-
  phase write and evaluates the result, never fabricating one.
- **pkgstate stays read-only.** Verification reads through pkgstate; the mutation
  lives here, in a separate sibling.

## 2. Scope of verbs

The nine contracted verbs, matching the pkexec entrypoints
(`/usr/libexec/pkgexec/runix-apt-*`):

| family | verbs | targets |
|---|---|---|
| transaction | `install`, `remove`, `purge`, `upgrade`, `dist_upgrade` | packages (`upgrade`/`dist_upgrade` take none) |
| update | `update` | none (whole source list) |
| hold | `hold`, `unhold` | packages |
| configure | `configure` | none (the pending set) |

`update` and `hold` are the two *autonomous* verbs (a member principal may run them
non-interactively, §4.2); every other verb is polkit-gated interactively.

## 3. The preview mechanism (the planner boundary): resolved contract

The preview needs the *exact* schema-1 `resource` + `plan_hash` a receipt will be
bound to. Re-deriving that in R would drift the moment apt's resolver, the digest
grammar, or the ownership predicate changed. So the preview is a **new, unprivileged,
read-only planner binary from pkgexec** (name **`runix-apt-preview`**), the *single
implementation* of the preview descriptor/digest. It is neither the root VM diagnostic
`pkgexec-plan` (which holds the dpkg lock and is never installed) nor an authority.

Pinned contract:

- **A separate, installed, unprivileged binary** `runix-apt-preview`. **Not** a
  `--preview` mode on the privileged entrypoints (privilege and preview stay
  separated), and **not** re-derived in R.
- **Reuses the committer's own code**: the same `pkgx_apt_map_txn` (resolve → schema-1
  record model) and `pkgx_digest_*` (canonical resource + hash) the nine effectors and
  the VM oracle use. One code path computes the digest, so a matching cache yields a
  matching hash.
- **Read-only, lockless, no mutation.** Opens the apt cache without the dpkg frontend
  lock, calls no committer, safe as any user any number of times.
- **Strict stdin request**, mirroring the entrypoint request grammar (verb fixed by
  the request, targets validated). **Stdout is reserved for one bounded, strict JSON
  object**; all libapt diagnostics go to **stderr**.
- **Structured data only.** The result carries `plan_schema`, `resource`, `plan_hash`,
  the resolved transaction as structured records (per package: action, from/to
  version, owned/protected/held flags), and an advisory policy verdict. **No human
  prose**; R/rctl render the display.
- **A genuine empty transaction is a typed `no_op`**, distinct from a refusal. On
  `no_op` pkgops opens **no intent** (there is nothing to receipt).
- **Advisory only.** The verdict authorizes nothing. The authoritative decision is the
  locked re-resolution inside the pkexec entrypoint at commit; if the cache moved, the
  recomputed `plan_hash` differs, `redeem_receipt` sees a hash mismatch, and the commit
  **fails closed (`no_intent`)** with nothing applied. Preview/commit consistency is a
  *binding* property, not a trust property.

## 4. The lifecycle

The pinned sequence, each step fail-closed. pkgops drives it in one R process; the
receipt never becomes an ordinary R value (§4.5).

```
preview → authorization (polkit) → broker capability available → open effect-required
  intent → private receipt pipe to the exact pkexec entrypoint → strict result parse
  → pkgstate verification → outcome
```

### 4.1 preview
Call `runix-apt-preview` for the verb+targets. A non-clean preview (planner missing,
malformed output, resolve failure, or an advisory refusal) **stops here** with a typed
preview error; a `no_op` also stops (nothing to do). No intent is opened.

### 4.2 authorization (polkit owns it; the broker does not)
Authorization is the per-verb polkit action on the pkexec entrypoint, never a broker or
pkgops decision. A denial is `runix_unauthorized`; the checked action is recorded as
`authorized_via`. Three cases, matching the contract's approval boundary:

- **Interactive (human, TTY):** the `pkexec` password prompt is the gate. Authorization
  happens when the entrypoint is invoked (§4.5); the human authenticates and the effect
  proceeds inline as one operation (one `correlation_id`, an intent and an outcome).
- **Machine mode (agent, no TTY):** a *noninteractive* polkit check. It must never
  block on a prompt. If the operation is gated and would require interaction, pkgops
  writes a **complete two-phase pair** (a plain intent and an `approval_required`
  outcome with `effect_issued = FALSE` under one `correlation_id`) and **stops**. No
  effect, no receipt minted. `approval_required` is a first-class terminal outcome,
  distinct from `unauthorized` and `ok`. **v1 does not resume**: a human re-runs a fresh
  interactive command that re-reads state and re-authorizes.
- **Autonomous `update`/`hold`:** proceed non-interactively **only when already
  authorized** (the `runix-apt-autonomous` membership); otherwise the machine-mode path
  above.

**v1 has no signed decisions and no policy tokens.** An optional UI confirmation may
front the interactive path, but it is not authorization and carries no durable approval
authority; the polkit action and, in machine mode, the `approval_required` record are
the only approval facts.

### 4.3 broker capability available (a precondition, not authorization)
Confirm the broker advertises the effect-receipt capability (a runtime, root-
authenticated probe) before opening an effect-required intent. This is *availability*,
not an authorization decision (§4.2 owns that). An absent capability or an unreachable
broker fails closed with a typed condition; nothing is invoked.

### 4.4 open effect-required intent
On the authorized proceed path only:
`open_intent(operation=verb, resource, effect={plan_schema, plan_hash})` over the
authenticated transport. The broker mints the durable intent and a **single-use effect
receipt** bound to `{principal, operation, resource, plan_schema, plan_hash}` and the
opener's full process identity. pkgops holds the `correlation_id`; the receipt is a
native secret from here (§4.5).

### 4.5 native receipt custody + the private pipe
The effect receipt must **never become an ordinary R string**: a `CHARSXP` cannot be
guaranteed wiped, and today's broker adapter parses it as one
(`audit_broker_sink.R`). So the receipt (and the outcome binding) live in an **opaque
native session** (C, in runix): the token is received into **wipeable heap memory**,
the session pipes it straight to the entrypoint over an **anonymous stdin pipe** (never
argv, a file, or the environment), and only *sanitized* fields (the `correlation_id`,
status, never the token) are ever exposed to R. The session zeroes and frees the
receipt on every exit path. The verb path invoked must be the exact verb previewed.

### 4.6 strict result parse
Parse the entrypoint's one strict JSON result
(`{status, effect_issued, correlation_id, detail}`) with the strict external parser
(janssonr): exact shape, dup-key rejecting, `effect_issued` a real boolean, and
`correlation_id` (when present) equal to the one held. `status` maps to a typed runix
condition through a **closed mapping pinned by a shared fixture corpus** (the same
corpus pkgexec's result channel is tested against, so the two never drift). A
malformed/short/duplicate result, or a cid that does not match, is
`runix_helper_bad_result` and is treated as **effect-unknown**, never as success.

### 4.7 pkgstate verification
Read native ground truth through pkgstate and check it against the approved plan, per
verb (§6.3). Verification is **independent** of the entrypoint's self-report: a clean
`status` with a post-state that disagrees is a verification failure, not a success.

### 4.8 outcome
Close the two-phase write with `write_outcome(correlation_id, outcome)` carrying the
honest result: the tri-state `effect_issued`, the mapped status, and the verification
verdict. The intent is **closed**, not left open, whenever the effect state is *known*:

- a strict helper result with `effect_issued = FALSE` (known truth) closes the outcome
  false;
- a known pkexec refusal *before* helper execution (e.g. an interactive denial, machine-
  mode `approval_required`) closes false;
- a successful, verified effect closes the outcome true.

The intent is **left open** only when the effect state is genuinely *unknown* (a
malformed/lost helper result), the process dies mid-flight, or the outcome itself cannot
be persisted. pkgops never fabricates an `effect_issued:false` to tidy up an unknown.

## 5. Per-verb R API (for review)

A uniform two-call shape per verb keeps authorization at the pkexec gate and the
committed object identical to the previewed one:

```r
p   <- pkgops::apt_install_preview(c("nginx"))  # -> pkgops_preview (advisory)
out <- pkgops::apt_install(p, ...)              # commits only p's {verb,resource,hash}
```

- `apt_<verb>_preview(targets, ...)` → a `pkgops_preview` (§6.1). Verbs with no targets
  (`update`, `upgrade`, `dist_upgrade`, `configure`) take none.
- `apt_<verb>(preview, ...)` → a `pkgops_outcome` (§6.2). It refuses a preview whose
  `{verb, resource, plan_hash}` it did not produce, and refuses a verb/preview mismatch.
- An optional combined `apt_<verb>_run(targets, ...)` for non-interactive callers is
  defined *in terms of* the two-call form, so there is no second code path.

The per-verb argument sets (lock timeout, allow-downgrade semantics, the autonomous
fast path) are part of this review.

## 6. Result schemas (for review)

Versioned, typed, neutral (built on runix's result shell), so rctl and agents consume a
stable shape.

### 6.1 `pkgops_preview`
`{schema_version, verb, resource, plan_schema, plan_hash, autonomous(bool),
transaction[ {package, action, from_version, to_version, owned, protected, held} ],
advisory_verdict, advisory_detail}`. Inert data; holding one grants nothing.

### 6.2 `pkgops_outcome`
`{schema_version, correlation_id, verb, resource, plan_hash, status,
effect_issued(TRUE|FALSE|NA), verified(TRUE|FALSE|NA), verify_detail, condition}`.
`effect_issued` is **tri-state**: `TRUE`/`FALSE` are known truth, `NA` is
effect-unknown (a malformed or lost helper result), and only `NA` (plus process death /
persist failure) leaves the intent open. `status` is the mapped runix condition from the
closed, fixture-pinned mapping (§4.6). The redeemed-no-outcome case is representable.

### 6.3 post-state predicates (per verb)
Verification (§4.7) is a per-verb native predicate, specified here so it is not
hand-waved:

| verb | post-state predicate | `verified` |
|---|---|---|
| install | each target present at the planned version | TRUE/FALSE |
| remove / purge | each target absent (purge: no residual config) | TRUE/FALSE |
| upgrade / dist_upgrade | the planned upgrades applied to their to-versions | TRUE/FALSE |
| hold / unhold | the dpkg selection reads back `hold` / `install` | TRUE/FALSE |
| configure | the pending set is configured (no incomplete state) | TRUE/FALSE |
| update | no meaningful pkgstate postcondition (remote index contents) | **NA** |

`update` verifies via the helper's own ground truth (indexes readable), not pkgstate, so
its `verified` is `NA` by design.

## 7. Fail-closed matrix (the invariant)

Every *unavailable*, *malformed*, or *mismatched* step fails closed, honest about
whether the host may have changed:

| step | failure | result |
|---|---|---|
| preview | planner missing / malformed / resolve fail / refusal / `no_op` | typed preview error or no_op; **no intent opened** |
| authorization | polkit denial | `runix_unauthorized`; **nothing invoked** |
| authorization | machine-mode challenge | `approval_required` pair, `effect_issued:false`, **closed**; stop |
| capability | broker down / capability absent | typed condition; **nothing invoked** |
| open_intent | transport / mint failure | typed condition; no receipt in hand |
| redeem (in helper) | hash drift, replay, actor/uid mismatch, expiry | `no_intent`; **nothing committed**; `effect_issued:false`, **closed** |
| helper result | `effect_issued:false` (known) | **closed** false |
| result parse | malformed / short / dup-key / cid mismatch | `runix_helper_bad_result`; **effect-unknown (NA)**; intent **left open** |
| verification | post-state disagrees | verification failure (not success) |
| process death / persist fail | after a durable intent | intent **left open**; never a fabricated false |

Receipt custody is **native, not R** (§4.5): the token lives in wipeable C memory, is
piped to the entrypoint, and is never a `CHARSXP`, never logged, never persisted.
Authorization is **polkit** (§4.2); there is no durable pkgops-side approval token.

## 8. Cross-repo boundaries

- **pkgexec**: adds the unprivileged read-only planner `runix-apt-preview` (§3),
  reusing `pkgx_apt_map_txn` + `pkgx_digest_*`; no change to the nine committing
  entrypoints or the redeem gate. Its own reviewed slice, VM-linked as before.
- **runix**: the native receipt-custody session (§4.5) is C in the common core; plus the
  typed conditions for the new failure modes (`runix_helper_bad_result`, preview /
  verification / capability conditions) through the shared taxonomy + retryability
  registry; result objects build on the neutral result shell.
- **runix-audit-broker**: no new capability; pkgops uses the existing
  `open_intent(+effect)` / `redeem` / `write_outcome` and the capability advertisement.
- **pkgstate**: the per-verb verification reads (§6.3). Confirm it exposes each native
  post-state predicate; add read-only accessors for any gap. Stays read-only.
- **rctl**: *last*. A `pkgops`-backed `apt.*` command surface (preview / run, machine
  mode surfacing `approval_required`), advertised via `rctl capabilities`, once the R API
  is stable.

## 9. Verification ladder

Contract (this doc) → R API + result schemas → unit tests against fakes (a fake planner,
a fake broker transport, a fake entrypoint, the native-session receipt custody, and
pkgstate fixtures; no root, no dpkg) → reuse of the destructive disposable-VM gate, where
the real `pkgops` replaces `rab-exercise` as the issuer and the existing §7 gates run
against it end to end. What cannot be faked (locks, maintainer scripts, interrupted
transactions, partial states) is proven only on the VM.

## 10. Open decisions for review

Resolved above (recorded so review can confirm): the planner is a separate installed
`runix-apt-preview` with a strict stdin request and stdout-reserved bounded JSON (§3);
authorization is polkit with the interactive / machine / autonomous split and no signed
tokens (§4.2); the outcome open-vs-close rule (§4.8); tri-state `effect_issued` (§6.2);
per-verb predicates with `update` = `NA` (§6.3).

Still open:

1. The `runix-apt-preview` result-channel field grammar (exact structured record shape)
   and its request grammar versus the entrypoint request.
2. The native receipt-custody session's R-facing surface (its handle type, and the exact
   sanitized fields it exposes).
3. Per-verb argument sets and the autonomous fast path's shape (still previews, still
   opens an intent when it proceeds).
4. Whether the machine-mode `approval_required` intent is plain (no effect binding), as
   assumed here, or effect-required-but-unredeemed.
5. Any pkgstate post-state accessor that does not yet exist for §6.3.
