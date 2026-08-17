# pkgops: the unprivileged apt-mutation issuer (plan)

**Status: approved 2026-08-17.** Build sequence, concrete signatures, and the review
rulings live in the companion `pkgops-implementation-plan.md`. This document is the
central contract for the second-and-final unit of the apt-mutation arc; it spans runix,
pkgexec, runix-audit-broker, and pkgstate, and reaches rctl at the end. It aligns with the
merged `apt-mutation-boundary-contract.md` (authorization, interactive vs machine mode) and
`libapt-pkg-helper-plan.md` (the effector boundary).

## 1. What pkgops is, and is not

`pkgops` is the **unprivileged, R-facing** layer that turns a requested apt mutation
into a *previewed → authorized → receipted → committed → verified → audited*
operation. It is the production issuer the Stage-4 VM stand-in (`rab-exercise`) was a
model of.

- **Unprivileged.** It runs as the calling (non-root) principal. It never holds the
  dpkg lock, never links `libapt-pkg` for mutation, and reaches privilege only by
  invoking a per-verb pkexec entrypoint that redeems a broker receipt.
- **Not the plan authority.** It does not re-derive the plan digest in R. The
  descriptor/resource/`plan_hash` come from a single shared implementation (§3); the R
  side only *carries* them. The **locked pkgexec re-resolution at commit stays
  authoritative**; any drift between preview and commit fails closed at redeem.
- **Not the authorization authority.** Polkit decides whether this principal may run
  the verb (§4.4). The broker advertises the effect-receipt capability and mints/
  redeems/records; it does not authorize.
- **Owns only its half of the audit.** The broker records the durable intent and
  outcome (audit actor = the real caller via `SO_PEERCRED`, never root); pkgexec issues
  the effect; pkgstate observes native state. pkgops *orchestrates* the two-phase write
  and evaluates the result, never fabricating one.
- **pkgstate stays read-only.** Verification reads through pkgstate; the mutation lives
  here, in a separate sibling.

## 2. Scope of verbs

The nine contracted verbs, matching the pkexec entrypoints
(`/usr/libexec/pkgexec/runix-apt-*`):

| family | verbs | targets |
|---|---|---|
| transaction | `install`, `remove`, `purge`, `upgrade`, `dist_upgrade` | packages, except `upgrade`/`dist_upgrade` (none) |
| update | `update` | none (whole source list) |
| hold | `hold`, `unhold` | packages |
| configure | `configure` | none (the pending set) |

`update` and `hold` are the two *autonomous* verbs (a member principal may run them
non-interactively, §4.4); every other verb is polkit-gated interactively.

## 3. The preview mechanism (the planner boundary): resolved contract

The preview needs the *exact* schema-1 `resource` + `plan_hash` a receipt will be bound
to. Re-deriving that in R would drift the moment apt's resolver, the digest grammar, or
the ownership predicate changed. So the preview is a **new, unprivileged, read-only
planner binary from pkgexec** (name **`runix-apt-preview`**), the *single
implementation* of the preview descriptor/digest. It is neither the root VM diagnostic
`pkgexec-plan` (which holds the dpkg lock and is never installed) nor an authority.

Pinned contract:

- **A separate, installed, unprivileged binary** `runix-apt-preview`. **Not** a
  `--preview` mode on the privileged entrypoints, and **not** re-derived in R.
- **Reuses the committer's own descriptor code, per verb.** The transaction descriptor
  already comes from the shared `pkgx_apt_map_txn`; the planner slice **extracts three
  read-only descriptor builders for `update`, `hold`, and `configure`** (today
  duplicated between their effectors and `tools/plan.cc`) so the planner and the
  effectors each call one implementation. With `pkgx_digest_*` on top, one code path per
  verb computes the digest, so a matching cache yields a matching hash. Mirrored
  enumeration with receipt-mismatch as the only backstop is rejected: it would weaken
  the single-source planner this arc deliberately chose.
- **Read-only, lockless, no mutation.** Opens the apt cache without the dpkg frontend
  lock, calls no committer, safe as any user any number of times.
- **Request grammar matches pkgexec v1**: a strict stdin request
  `{schema_version, verb, packages}` and nothing else. Package targets are accepted
  **only** for `install`/`remove`/`purge`/`hold`/`unhold`; `update`/`upgrade`/
  `dist_upgrade`/`configure` take **none**. **No allow-downgrade option and no
  pass-through apt flags** (the helper supports neither), and **no `lock_timeout`** (a
  commit-time argument, meaningless to a lockless preview).
- **Stdout is reserved for one bounded, strict JSON object**; all libapt diagnostics go
  to **stderr**.
- **Structured, verb-specific records only** (§6.1); **no human prose** (R/rctl render
  the display). It echoes back the original validated `packages[]` so the R side never
  reconstructs helper targets from `resource`.
- **A genuine empty transaction is a typed `no_op`**, distinct from a refusal. On
  `no_op` pkgops opens **no intent**.
- **Advisory only.** The verdict authorizes nothing. The authoritative decision is the
  locked re-resolution inside the pkexec entrypoint at commit; if the cache moved, the
  recomputed `plan_hash` differs, `redeem_receipt` sees a mismatch, and the commit
  **fails closed (`no_intent`)** with nothing applied. Preview/commit consistency is a
  *binding* property, not a trust property.

## 4. The lifecycle

Authorization is polkit and its timing is mode-dependent, so the flow **branches**;
each step fails closed.

```
preview → (optional UI confirmation) → broker capability available
  ├─ machine-mode: polkit challenge or denial
  │      → PLAIN intent + terminal false outcome (approval_required | unauthorized) → stop
  ├─ machine/autonomous, already authorized
  │      → effect-required intent → native effect session → helper → parse → verify → outcome
  └─ interactive
         → effect-required intent → native effect session → pkexec PROMPT
            ├─ authenticated → helper → parse → verify → outcome
            └─ denied → known-false outcome (unauthorized), close
```

### 4.1 preview
Call `runix-apt-preview`. A non-clean preview (planner missing, malformed, resolve
failure, refusal) or a `no_op` **stops here**; no intent is opened.

### 4.2 optional UI confirmation
A UI confirmation may front the interactive path, but it is **not authorization** and
carries no durable approval authority. Declining ends the operation with no side
effect. v1 has **no signed decisions and no policy tokens**.

### 4.3 broker capability available
Confirm the broker advertises the effect-receipt capability (a runtime, root-
authenticated probe) before any intent is opened. This is *availability*, not
authorization. Absent capability or an unreachable broker fails closed; nothing is
invoked.

### 4.4 authorization (polkit) and the intent branch
Polkit owns authorization; a denial is `runix_unauthorized`, and the checked action is
recorded as `authorized_via`.

- **Machine mode (agent, no TTY):** a *noninteractive* polkit check (`pkcheck`), never
  a prompt. If it denies or would require interaction, pkgops opens a **plain intent
  (no effect binding, no receipt minted)** and writes the matching terminal outcome
  (`approval_required` for a needed challenge, `unauthorized` for a denial) with
  `effect_issued = FALSE` under one `correlation_id`, then **stops**. **Ruling: the
  machine-mode terminal path uses a plain intent** so no unused effect receipt becomes
  durable state. v1 does not resume; a human re-runs a fresh interactive command.
- **Autonomous `update`/`hold`:** proceed non-interactively **only when already
  authorized** (`runix-apt-autonomous` membership); otherwise the machine-mode path.
- **Interactive / already-authorized machine:** proceed to the **effect-required
  intent** (§4.5). For interactive, the actual authentication is the `pkexec` prompt
  during the helper spawn; a cancelled prompt is a known-false `unauthorized` outcome
  on that intent (the minted receipt is wiped unredeemed).

### 4.5 the native effect session
The receipt must **never become an ordinary R string** (a `CHARSXP` cannot be
guaranteed wiped, and the current broker adapter parses it as one in
`audit_broker_sink.R`). The proceed path runs inside a **native effect session: an
exported, supported runix API** (not `runix:::`) returning an **opaque, tagged,
PID-bound external pointer**. It opens the effect-required intent
(`open_intent(operation=verb, resource, effect={plan_schema, plan_hash})`, receipt into
wipeable heap), spawns the entrypoint, and delivers the receipt.

State machine: `opened → receipt_sent → result_known | effect_unknown →
outcome_attempted → closed`. Requirements:

- **One helper launch and at most one outcome attempt.** Re-use, a child/fork of the
  handle, and a deserialized handle are all refused.
- **Receipt wiped immediately after pipe delivery** (anonymous stdin pipe only; never
  argv, a file, or the environment).
- **Outcome binding retained natively** until the outcome attempt, then wiped.
- **The finalizer only wipes** (receipt, binding, buffers); it never fabricates or
  writes an outcome.
- **Native absolute-path spawn** of `pkcheck`/`pkexec` (no shell, no `system2`), with
  bounded stdout/stderr and a deadline.
- Only *sanitized* fields (the `correlation_id`, the parsed status) are ever exposed to
  R.

### 4.6 strict result parse
Parse the entrypoint's one strict JSON result
(`{status, effect_issued, correlation_id, detail}`) with janssonr: exact shape,
dup-key rejecting, `effect_issued` a real boolean, `correlation_id` (when present)
equal to the one held. `status` maps to a typed runix condition through a **closed
mapping pinned by a shared fixture corpus** (the same corpus pkgexec's result channel
is tested against, so the two never drift). A malformed/short/duplicate result, or a
cid mismatch, is `runix_helper_bad_result` and is treated as **effect-unknown**.

### 4.7 pkgstate verification
Read native ground truth through pkgstate and check the approved plan, per verb (§6.3).
Verification is **independent** of the entrypoint's self-report: a clean `status` with
a disagreeing post-state is a verification failure, not a success.

### 4.8 outcome
Close the two-phase write with `write_outcome(correlation_id, outcome)`. **Any strict,
parseable helper result is known truth and closes the outcome** with its reported
`effect_issued`, mapped status, and verification verdict: `ok`, `operation_failed`,
`dpkg_broken`, `no_intent`, and the rest alike (a `dpkg_broken` with
`effect_issued=TRUE` is known: the host was touched and left broken). A known
pre-execution refusal (interactive denial, machine-mode `approval_required`/
`unauthorized`) also closes, false. The intent is **left open only** when the effect
state is genuinely *unknown* (a malformed/lost helper result), the process dies
mid-flight, or the outcome itself cannot be persisted. pkgops never fabricates an
`effect_issued:false`.

## 5. Per-verb R API (for review)

A uniform two-call shape keeps authorization at the polkit gate and the committed
object identical to the previewed one:

```r
p   <- pkgops::apt_install_preview(c("nginx"))  # -> pkgops_preview (advisory)
out <- pkgops::apt_install(p, lock_timeout = 300) # commits only p's {verb,resource,hash}
```

- `apt_<verb>_preview(targets)` → a `pkgops_preview` (§6.1). Targets are accepted only
  for `install`/`remove`/`purge`/`hold`/`unhold`; `update`/`upgrade`/`dist_upgrade`/
  `configure` take none. **No allow-downgrade and no pass-through apt flags** (the
  helper supports neither).
- `apt_<verb>(preview, lock_timeout = ...)` → a `pkgops_outcome` (§6.2). `lock_timeout`
  is a **commit-time** argument (it belongs here, not to the lockless preview). It
  refuses a preview whose `{verb, resource, plan_hash}` it did not produce, and a
  verb/preview mismatch.
- An optional combined `apt_<verb>_run(targets, lock_timeout = ...)` is defined *in
  terms of* the two-call form, so there is no second code path.

## 6. Result schemas (for review)

Versioned, typed, neutral (built on runix's result shell).

### 6.1 `pkgops_preview`
`{schema_version, verb, resource, plan_schema, plan_hash, autonomous(bool),
packages[]` (the original validated targets, never reconstructed from `resource`)`,
records[], advisory_verdict, advisory_detail}`. `records` is **verb-specific**, matching
the digest record types (so the preview shows exactly what the hash bound):

| verb family | record fields |
|---|---|
| transaction | `package, architecture, action, from_version, to_version, flags[]` (flags ⊆ `hold, auto, essential, protected`; there are **no** separate `owned`/`protected`/`held` fields, and no `owned` flag) |
| hold / unhold | `package, from_state, to_state` |
| configure | `package, architecture, current_version, state` |
| update | `uri, suite, components[], options{}` (identity-relevant options) |

(Grammar corrected 2026-08-17 against shipped pkgexec 0.0.3: configure's field is `state`,
not `dpkg_state`; transaction carries a `flags[]` array, not separate `owned`/`protected`/
`held` fields — `pkgexec` `digest.h:32-41`, `preview.cc:146-165`.)

It is inert data; holding one grants nothing.

### 6.2 `pkgops_outcome`
`{schema_version, correlation_id, verb, resource, plan_hash, status,
effect_issued(TRUE|FALSE|NA), verified(TRUE|FALSE|NA), verify_detail, condition}`.
`effect_issued` is **tri-state**: `TRUE`/`FALSE` are known truth (and close the
outcome, §4.8), `NA` is effect-unknown (only `NA`, plus process death / persist
failure, leaves the intent open). `status` is the mapped runix condition from the
closed, fixture-pinned mapping (§4.6).

### 6.3 verification predicates (per verb)
Verification (§4.7) checks **every resolved record** in the preview, not only the
requested targets: dependency installs, removals, purges, upgrades, and downgrades all
included.

- **install / remove / purge / upgrade / dist_upgrade / configure:** the existing
  `pkgstate::dpkg_installed()` already covers presence, version, and incomplete-state
  (half-configured / half-installed / unpacked) checks; each resolved record is checked
  to its planned post-state.
- **hold / unhold:** pkgstate needs **one new read-only accessor** for the dpkg
  selection (`install` vs `hold`); the changed targets must read back in the intended
  selection.
- **update:** no meaningful pkgstate postcondition (remote index contents), so
  `verified = NA`; the helper's own ground truth (indexes readable) stands.

## 7. Fail-closed matrix

| step | failure | result |
|---|---|---|
| preview | planner missing / malformed / resolve fail / refusal / `no_op` | typed error or no_op; **no intent** |
| authorization | machine-mode challenge or denial | **plain intent** + terminal false outcome (`approval_required`/`unauthorized`), stop |
| authorization | interactive prompt cancelled | known-false `unauthorized` outcome; receipt wiped unredeemed |
| capability | broker down / capability absent | typed condition; **nothing invoked** |
| open_intent | transport / mint failure | typed condition; no receipt in hand |
| redeem (in helper) | hash drift, replay, actor/uid mismatch, expiry | `no_intent`; nothing committed; **known result → closed** false |
| helper result | any strict result (`ok`/`operation_failed`/`dpkg_broken`/...) | **closed** with its reported `effect_issued` + status + verification |
| result parse | malformed / short / dup-key / cid mismatch | `runix_helper_bad_result`; effect-unknown (`NA`); intent **left open** |
| verification | post-state disagrees | verification failure (not success) |
| process death / persist fail | after a durable intent | intent **left open**; never a fabricated false |

Receipt custody is **native, not R** (§4.5). Authorization is **polkit** (§4.4); there
is no durable pkgops-side approval token.

## 8. Cross-repo boundaries

- **pkgexec**: adds the unprivileged read-only planner `runix-apt-preview` (§3), and
  performs a **behavior-preserving extraction** of three shared read-only descriptor
  builders (`update`, `hold`, `configure`) that both the planner and the existing
  `apt_update` / `apt_hold` / `apt_configure` effectors call (the transaction path
  already shares `pkgx_apt_map_txn`); the redeem gate and commit logic are unchanged.
  The slice ships **byte-identical digest/golden tests for every verb, planner-versus-
  effector parity tests, and disposable-VM coverage for `update`, `hold`/`unhold`, and
  `configure` before the refactor merges**. Its own reviewed slice, VM-linked.
- **runix**: the **exported native effect-session API** (§4.5) is C in the common core;
  plus the typed conditions for the new failure modes (`runix_helper_bad_result`,
  preview / verification / capability conditions) through the shared taxonomy +
  retryability registry; result objects build on the neutral result shell.
- **runix-audit-broker**: no new capability; pkgops uses the existing
  `open_intent(+effect)` / `redeem` / `write_outcome` and the capability advertisement.
- **pkgstate**: the per-verb verification reads (§6.3); reuses `dpkg_installed()`, adds
  **one** read-only dpkg-selection accessor for hold/unhold. Stays read-only.
- **rctl**: *last*. A `pkgops`-backed `apt.*` command surface (preview / run, machine
  mode surfacing `approval_required`), advertised via `rctl capabilities`, once the R
  API is stable.

## 9. Verification ladder

Contract (this doc) → R API + result schemas → unit tests against fakes (a fake planner,
a fake broker transport, a fake entrypoint, the native-session state machine, and
pkgstate fixtures; no root, no dpkg) → reuse of the destructive disposable-VM gate,
where the real `pkgops` replaces `rab-exercise` as the issuer and the existing §7 gates
run against it end to end. What cannot be faked (locks, maintainer scripts, interrupted
transactions, partial states) is proven only on the VM.

## 10. Resolved in review

The planner boundary and the shared per-verb descriptor extraction (§3, §8), the
branched lifecycle with a plain machine-mode `approval_required` intent (§4), the native
effect-session state machine (§4.5), the known-effect-closes outcome rule (§4.8), the
verb-specific records and pinned request grammar (§3, §6.1), tri-state `effect_issued`
(§6.2), and the per-verb verification including every resolved record (§6.3) are all
settled here. Remaining detail (the exact record field grammar of `runix-apt-preview`,
the native session's R-facing handle type, and the one new pkgstate selection accessor's
signature) is implementation detail for the pkgexec planner slice (which also lands the
update/hold/configure builder extraction behind byte-identical golden + planner/effector
parity + disposable-VM tests), the runix session API, and the pkgstate accessor
respectively, each its own small reviewed change; no further broad design round.
