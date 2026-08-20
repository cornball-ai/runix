# pkgops VM-gate increment — plan (durable record grammar + disposable-VM proof)

Status: **DRAFT for review.** No code and no VM activity until this plan is
approved. `pkgops` PR #9 (the exported `apt_<verb>()` commit API) stays a draft
until the proof in this plan passes.

## 0. Why this increment exists

PR #9 made `pkgops` mutation-capable (nine exported `apt_<verb>(preview)`), but
two things are still unproven and gate any release:

1. **The durable record is minimal.** `.outcome_record()` writes only
   `{operation, resource, effect_issued}`. The verification verdict from 5b
   (`verified` / `verify_detail`) lives only in the in-memory `pkgops_outcome`; it
   never reaches the durable audit line. A commit that silently failed
   verification is not distinguishable in the audit log from one that passed.
2. **The real broker/polkit path is unproven.** Every `pkgops` test to date is
   hermetic (fake session-ops, fake pkcheck, fake reader). No test has driven the
   real `apt_<verb>(preview) -> pkexec entrypoint -> broker -> durable record`
   path against a real dpkg, a real broker, and real polkit.

This increment closes both. It splits into **Part A** (the durable record
grammar: code, hermetic, holdable now) and **Part B** (the disposable-VM proof:
the destructive gate on the troy-g5 VM). PR #9 merges only after Part B is green.

---

## 1. Broker record schema — PINNED

The durable audit record is a **flat, closed allow-list**, schema version `1`. Two
enforcement layers matter.

### 1.1 Version

- The record `schema_version` and the advertised `record_schema_version` are both
  the literal **`1`**.
- The `RECORD_SCHEMA` constant that defines the allow-list lives in
  **`runix-audit-broker/src/json.c`** (NOT in runix). runix references it by name
  in `docs/apt-mutation-boundary-contract.md:27-28,320` and
  `docs/broker-effect-receipt-contract.md:384` ("Public audit-record schema …
  unchanged").
- **The client never sends `schema_version`.** The broker stamps it. The client
  sends only `{type:"write_outcome", binding, record}`
  (`runix/R/audit_broker_sink.R:396`; C path `runix/src/effect_session.c:722-725`,
  which inserts the binding in C so it never crosses R).
- The broker advertises `record_schema_version` in its `capabilities` response
  (`runix/R/audit_broker_sink.R:121-122`, validated `:175-176`; captured
  `runix/R/effect_capability.R:120-121`; wire fixture
  `runix/inst/tinytest/fixtures/broker-frames/capabilities_ok.json` →
  `"record_schema_version":1`). The current client gates only on the
  effect-receipt extension version and `plan_schema` membership, not on
  `record_schema_version` — so a schema-version mismatch surfaces as a broker-side
  `schema_invalid` on write, not a client-side pre-check.

### 1.2 Reserved fields (broker-filled; REJECTED if a client sends them)

`runix/R/audit_broker_sink.R:200-202`, error code `runix_broker_reserved_field`:

```
schema_version, record_type, correlation_id, phase, host, pid, actor, time,
binding, broker
```

The broker's own authoritative reserved set is the 7 identity/framing keys
(`correlation_id, actor, phase, host, pid, time, schema_version`;
`docs/apt-mutation-boundary-contract.md:323-325`); the R adapter adds
`record_type, binding, broker` locally. `actor` is broker-derived from
`SO_PEERCRED` and rejected if client-supplied
(`docs/durable-audit-contract.md:162-174`).

### 1.3 Domain allow-list (the 16 fields a client MAY send)

`docs/apt-mutation-boundary-contract.md:320-323`:

```
operation, outcome, resource, scope, audit_scope, authorized_via,
completion_method, job_result, observed_reason, preview, effect_issued,
changed, state_changed, observed_failed, elapsed, observed
```

**Any field not on this list is hard-rejected as `schema_invalid`**
(`docs/apt-mutation-boundary-contract.md:325-327`, `docs/audit-broker-contract.md:462`).
There is **no free-form sub-object** for issuer-specific keys.

Critical asymmetry to design around: the R adapter enforces only the *reserved*
list locally, not the *positive* allow-list; the native
`effect_session_write_outcome` path does no field check at all beyond "named
list" (`runix/R/effect_session_api.R:159-162`). So a stray field like a literal
`verified` **passes every R-side check and is rejected only at the broker**. This
is why Part B (a real broker) is mandatory: a mis-named field is invisible to
hermetic tests and fails only against the real broker.

### 1.4 The persisted line

`docs/durable-audit-contract.md`, "Record schema (persisted line)" at line 112
(the exact target of the `.outcome_record()` reference "durable-audit-contract.md:112"):
append-only JSONL, deterministic key order, one object per line. `observed` =
the post-state actually read (may be `NA` under the `observed_failed` rule,
`:135-136`); `changed` = the verb-specific functional effect **as verified against
the read-back state**; `state_changed` = the raw observed-field transition. When a
verb reads no post-state -- an index refresh (`apt.update`) exposes no per-package
or index state pkgops reads -- `observed`, `changed`, and `state_changed` are all
**omitted**, never inferred from `effect_issued`. Preview/no-op records carry
`effect_issued=false`.

---

## 2. The exact durable fields pkgops writes — PROPOSAL

`verified` / `verify_detail` are **not** broker fields and must never be written
as literal keys. They map into the existing allow-list post-state fields — which
is exactly the "observed / changed verification grammar" this increment is gated
on. **No broker `RECORD_SCHEMA` change, no `schema_version` bump.**

### 2.1 The broker's fixed types (the hard gate)

`runix-audit-broker/src/json.c:26-43,86-101` validates each field's **type**
(every field optional; JSON `null` accepted for all; a wrong type is rejected
`schema_invalid`; `T_NUMBER` must be `>= 0`):

- `observed` — **`T_OBJECT`** (or null). Its internal keys are unconstrained
  (only a depth cap `RAB_MAX_DEPTH`). **This is the only object-typed field**, so
  every per-package detail lives here.
- `changed`, `state_changed`, `observed_failed`, `effect_issued`, `preview` —
  **`T_BOOL`** (scalar boolean or null). **Not** objects: a per-package structure
  here is rejected.
- `observed_reason` — `T_STRING`; `elapsed` — `T_NUMBER (>= 0)`; `operation`,
  `resource`, `scope`, `audit_scope`, `authorized_via`, `outcome`,
  `completion_method`, `job_result` — `T_STRING`.

### 2.2 `.outcome_record()` grows from 3 fields to this set

| record field | type | source |
|---|---|---|
| `operation` | string | `outcome$verb` (already written) |
| `resource` | string | `outcome$resource` (already written) |
| `effect_issued` | bool | `outcome$effect_issued` (already written; helper's boolean) |
| `scope` | string | constant `"system"` (apt mutates system state) |
| `authorized_via` | string | the `.authorize()` provenance (§2.4): `pkexec`/`autonomous`/`pkcheck` |
| `preview` | bool | constant `false` (a commit, not a preview/no-op) |
| `observed` | **object/null** | the per-package post-state pkgstate read (§2.5); `null` for update or a read failure |
| `changed` | **bool/null** | the verb-specific functional effect: `TRUE` iff every resolved record matched its planned post-state; `FALSE` on a mismatch; `null` when unverifiable |
| `state_changed` | **bool/null** | the **observed** before/after diff (D7 = S-B): `TRUE` iff any observed field differs between the pre-commit and post-commit `pkgstate` snapshots, `FALSE` iff none differs, `null` whenever **either** snapshot is unavailable. Never derived from `effect_issued` (an issued effect need not have changed state) |
| `observed_failed` | bool | `TRUE` only when the post-state could **not be read** (`pkgstate` errored); then `observed = null` |
| `observed_reason` | string/null | `verify_detail` — the reason on a mismatch or a read failure |

**Correction from the first draft:** `changed`/`state_changed` are **scalar
booleans**, not per-record objects — the broker's `T_BOOL` gate rejects an object
there (`json.c:39`). The raw per-package transition therefore lives inside
`observed`, not in `state_changed`. `state_changed` is reduced to the whole-record
"did disk move" scalar; `changed` is the whole-record verification verdict.

Broker-lifecycle fields (`outcome`, `completion_method`, `job_result`, `elapsed`)
are strings/number and follow the durable-audit contract's vocabulary
(`outcome ∈ {persisted, open, ...}`, the broker's own `outcome_ok = {ok,
persisted}`). **Note the byte-comparability limit:** the `rab-exercise` oracle
writes a *placeholder* `observed = {status, detail}` and omits
`changed`/`state_changed` entirely (`runix-audit-broker/tools/rab-exercise.c:468-472`).
pkgops is the real issuer and writes a **richer** `observed` plus real
`changed`/`state_changed`, so its record is deliberately **not** byte-identical to
`rab-exercise`'s. Part B asserts broker **acceptance** (types + allow-list) and
value **correctness** against the known post-state, not byte-equality with the
placeholder (§5, corrected).

### 2.3 The `verified` tri-state → durable mapping

`null` below is JSON `null` (R `NA`); "absent" means the key is omitted. `changed`
and `state_changed` are scalar booleans/null (§2.1).

`state_changed` is a separate axis (the pre/post diff), so it is shown as its own
column and is `null` whenever the pre- **or** post-snapshot is unavailable.

| `pkgops_outcome$verified` | `observed` | `changed` | `state_changed` | `observed_failed` | `observed_reason` |
|---|---|---|---|---|---|
| `TRUE` (post-state matched) | per-pkg read state (§2.4) | `true` | pre≠post diff, else `null` | `false` | absent |
| `FALSE` — **mismatch** (read OK, disagreed) | per-pkg read state (§2.4) | `false` | pre≠post diff, else `null` | `false` | `verify_detail` |
| `FALSE` — **read failure** (post read errored) | `null` | `null` | `null` (post unavailable) | `true` | `verify_detail` |
| `NA` — no post-state (update) | `null` | `null` | `null` (nothing observable) | `false` | absent |

**Wire realization:** pkgops writes every optional `null` in this table by
**omitting the key** (`.outcome_record`'s NA/NULL-omit rule); the broker reads an
absent optional field as null (§2.1), so `null` and an omitted key are the same wire
outcome for an optional. `operation`/`resource`/`effect_issued`/`scope`/`preview` are
always present. So an `apt.update` record carries exactly those five plus
`authorized_via` and `observed_failed=false`; `observed`, `changed`, and
`state_changed` are absent (never a fabricated `state_changed=true`).

This needs the verification layer to distinguish **mismatch** from **read failure**
— which 5a/5b collapse into a single `verified=FALSE`. Part A enriches `.verify()`
to return the per-record observed post-state plus a read-vs-mismatch flag, behind
the existing reader seam (still hermetic). `changed` is the whole-record verdict
(all records matched their plan); `state_changed` is the observed pre/post diff
(D7 = S-B), `null` when either snapshot is missing.

### 2.4 The exact `observed` object shapes (per verb family) — PINNED

`observed` is the only object-typed field, so it carries all per-package detail. It
is a JSON **object keyed by `package:arch`** -- the qualified identity verification
matches on -- one entry **per resolved record — including dependency records**, not
only the requested targets. Transaction and configure records always carry an
architecture, so each is exactly one `package:arch` entry. **Hold/unhold records
carry no architecture**, so an unqualified hold target records **one `package:arch`
entry per matched selection row**, ordered deterministically (radix on
architecture): a change confined to a single architecture is then visible in the
pre/post diff, where a single collapsed entry would hide it (while `.verify_hold`,
which checks every row, still fails). A target that matches no selection row is
documented under its identity (bare `package`, or `package:arch` if it named one)
with a `null` selection. `observed` is `null` when there is no post-state. Nothing
today pins the apt `observed` internal shape (the `rab-exercise` `{status,detail}`
is a placeholder), so pkgops defines it:

**Transaction** (install / remove / purge / upgrade / dist_upgrade) — value =
`{status, version}` (the dpkg state word + installed version read back):
```json
"observed": {
  "nginx:amd64":  {"status": "installed",     "version": "1.2"},
  "libfoo:amd64": {"status": "installed",     "version": "3.4"},
  "oldbar:amd64": {"status": "config-files",  "version": "9"},
  "gonebar:amd64":{"status": "not-installed", "version": ""}
}
```

**Hold / unhold** — value = `{selection}` (the dpkg want word read back), one entry
per matched architecture (an unqualified target can be held on several arches):
```json
"observed": {"nginx:amd64": {"selection": "hold"}, "nginx:i386": {"selection": "hold"}}
```

**Configure** — value = `{status}` (must be `installed` post-configure):
```json
"observed": {"nginx:amd64": {"status": "installed"}}
```

**Update** — no observable post-state, and pkgops reads no apt **index** state, so
`observed`, `changed`, and `state_changed` are all **omitted** (`observed: null` in
the outcome; the three keys never written). A successful refresh is not proof that
any tracked state moved, and pkgops never fabricates the transition from
`effect_issued`:
```json
"observed": null   // `changed` and `state_changed` omitted as well
```

**Failure** (`operation_failed` / `dpkg_broken`) — same per-package `{status,
version}` shape, carrying the actual (broken/partial) read-back, e.g. a
half-configured package:
```json
"observed": {"nginx:amd64": {"status": "half-configured", "version": "1.2"}}
```

**Read failure** (pkgstate errored) — `observed: null` with `observed_failed: true`
and `observed_reason` set (the pinned NA representation,
`phase2-mutation-contract.md:324-325`).

`status` values are the dpkg state words `pkgstate::dpkg_installed()` returns
(installed / config-files / half-installed / unpacked / half-configured /
triggers-* / not-installed); `selection` is the want word from
`pkgstate::dpkg_selections()` (install / hold). The key is `package:arch` — the
same qualified identity verification matches on (`verify.R:189-195,261-265`) — so a
multi-arch commit is unambiguous.

### 2.5 `authorized_via` provenance — PINNED

The value is **decided at the `.authorize()` point from state that is complete
there**, and **returned by `.authorize()`** as part of its result. Nothing
downstream reconstructs it from partial state.

Today `.authorize(verb_spec, interactive)` (R/polkit.R, 4a/4b) returns the bare
string `"authorized"` for three different paths, losing the distinction. The fix
is to make the success result carry the provenance:

```
.authorize() success result  ->  list(status = "authorized", via = <provenance>)
.authorize() refusal results ->  unchanged ("unauthorized" / "approval_required"
                                  / "check_failed"); via is NA (nothing authorized)
```

`via` is determined from the three facts all known AT the decision point —
`interactive` (the mode), `verb_spec$autonomous` (the verb's polkit class), and the
machine-mode `pkcheck` rc:

| condition (all known at `.authorize`) | `via` |
|---|---|
| `interactive == TRUE` | `"pkexec"` — the prompt authenticates at the privileged spawn |
| `interactive == FALSE`, `pkcheck` rc 0, `verb_spec$autonomous == TRUE` | `"autonomous"` — the `runix-apt-autonomous` rule is the only non-interactive grant for `update`/`hold` |
| `interactive == FALSE`, `pkcheck` rc 0, `verb_spec$autonomous == FALSE` | `"pkcheck"` — a non-interactive polkit grant for a normally-admin verb |

`.commit_session` threads `via` from the decision object into the outcome, and
`.outcome_record()` writes it as `authorized_via` on the effect-intent record
(present on every closed effect-intent outcome — success or a downstream helper
failure — since the authorization did happen before the intent opened; absent on a
plain-intent refusal record, which authorized nothing).

**Honest scope of the label.** `pkcheck` returns only rc 0/1/2/3; it does not
expose *which* polkit rule granted. So `"autonomous"` is defined precisely as "a
machine-mode grant of an autonomous-class verb (`update`/`hold`)", not a proof that
the `runix-apt-autonomous` rule fired. This is the audit-meaningful distinction (a
change made with no human in the loop, sanctioned by the autonomous class) and it
is a *definition from known state*, not a post-hoc inference from incomplete state.
Part B's polkit matrix already backs it: in machine mode only autonomous-class
verbs get rc 0 for a member, and non-members get rc 1 (`polkit-matrix.sh` PROOFs
1-3). This definition (D6) is called out for sign-off.

---

## 3. Part A — the durable record grammar (code, hermetic, holdable)

Its own reviewed PR, merged to master **before** the VM proof. Safe to merge while
#9 is held: master stays preview-only + internal `.commit_session` (no exported
mutation), so the enriched record affects nothing a user can invoke yet.

Scope:
1. A per-record `pkgstate` **observer** (`R/verify.R`) that reads the resolved
   records' state into the §2.4 `observed` object (status+version, or selection),
   behind the existing reader seam. `.verify()` reuses it for the post-state and
   also returns a `mismatch` vs `read_failure` distinction.
2. A **pre-commit snapshot** in `.commit_session` (D7 = S-B): call the observer
   **before** the effect-session commit to capture `before`; the post-commit read
   is `after`. `state_changed` = `before != after` on the observed fields, and
   `null` whenever either snapshot is unavailable (a pre- or post-read failure, or
   no observable state as for update). Never derived from `effect_issued`. The
   pre-read is on the same reader seam, so the lifecycle stays hermetic; it adds one
   read before the commit and changes no control flow.
3. Expand `.outcome_record()` (`R/commit.R`) to the §2.2 field set: map the verdict
   per §2.3, build `observed` per §2.4, `authorized_via` per §2.5, `state_changed`
   per D7=S-B. It must emit **only** allow-list fields with the right **types** — a
   constant `.PKGOPS_RECORD_FIELDS` pinned to the 16-field allow-list plus a
   per-field type map (`observed` object, `changed`/`state_changed`/`observed_failed`
   bool, `observed_reason` string), with a test asserting the built record's
   `names()` are a subset, the types match, and no reserved key appears.
4. Vendor the broker-frame fixtures the plan already calls for (`pkgops`
   implementation-plan §4.7: pkgexec `tests/fixtures/broker-frames/*.json`, 7
   files) and add a hermetic test that the built record would pass the broker's
   allow-list + type gate (subset + type check) and carries no reserved key.

Hermetic proof only. The real allow-list + type enforcement is broker-side
(§1.3/§2.1), and the R side never checks the positive allow-list, so Part A's
subset/type test is necessary but not sufficient — Part B against the real broker
is the authority.

---

## 4. Part B — the disposable-VM proof

Reuses the existing apt canary harness **unchanged in shape**, swapping the issuer
from the `rab-exercise` oracle to real `pkgops::apt_<verb>()`. Per the plan's
verification ladder (`docs/pkgops-plan.md:298` §9; `docs/pkgops-implementation-plan.md:361`
§6 step 4): "the real `pkgops` replaces `rab-exercise` as the issuer and the
existing §7 gates run against it end to end."

### 4.1 Harness location (all in runix)

- Driver (KVM host): `deploy/canary-apt/apt-canary-guest.sh <stage-dir>` —
  orchestrates install → fixtures → `polkit-matrix.sh` → `apt-gates.sh`, collects
  evidence, prints `==== matrix rc=$M gates rc=$G ====`, exits 0 iff both 0.
- Suites (in guest): `deploy/canary-apt/polkit-matrix.sh` (the **23** polkit-boundary
  assertions) and `deploy/canary-apt/apt-gates.sh` (the **37** §7 acceptance
  assertions).
- Support: `install-apt-stack.sh`, `apt-fixtures.sh`, `fcntl-lock.c`, `redact.jq`,
  and the VM-only pkgops launcher `apt-issue.sh` / `apt-issue.R` (never packaged).
- Staging (workstation): `deploy/canary-apt/build-and-stage.sh <kvm-host>`.
- Provision/teardown (shared): `deploy/canary/provision.sh` (+ `provision.sh destroy`).

### 4.2 Harness commits (what this increment changes and pins)

The harness runs from **committed SHAs only** (`build-and-stage.sh` refuses a dirty
tree and `git archive`s from the pinned commits, never the worktree). This
increment pins these into a fresh `MANIFEST`:

- `runix-audit-broker` — the broker `.deb` + `rab-exercise` (still built; used as
  the record-shape oracle for §2.1's broker-lifecycle fields).
- `pkgexec` **0.0.3** — the nine entrypoints, `runix-apt-preview`, the polkit
  policy + `49-runix-apt-autonomous.rules`, the `runix-apt-autonomous` group.
- `runix` — the deploy scripts, at the commit that carries the two harness edits
  below.
- `pkgstate` **0.0.1.9** — installed as an R package in the guest (new).
- `pkgops` — the **#9 + Part A** branch (new).

Two harness edits (their own commit in `runix/deploy/canary-apt/`, reviewed):

1. `install-apt-stack.sh` also installs the R stack in the guest (r2u/rapt: R +
   `janssonr`, `pkgstate` 0.0.1.9, `runix` 0.0.1.12, `pkgops` #9+PartA), matching
   the A1 slice's R-stack install pattern.
2. `apt-gates.sh` drives the **functional** gates through the real pkgops path via a
   thin VM-only launcher `apt-issue` (`apt-issue.sh` → `apt-issue.R`), which calls
   `pkgops::apt_<verb>(apt_<verb>_preview(...))` and prints one `RESULT` line in the
   `rab-exercise` grammar (same tokens, same exit codes: 0 persisted / 1 pre-intent /
   3 left-open), so each gate's assertions (status, `effect_issued`, dpkg post-state,
   temp-grant setup/teardown) stay identical. The split is deliberate:

   - **The functional gates** run through real pkgops (`apt-issue`). This includes G9
     (protected) and G-OWN (not-owned): these surface as **preview-side refusals**
     inside pkgops (`apt_<verb>_preview()` raises the refusal status before any intent
     is opened), so `apt-issue` emits them with `effect_issued=false` /
     `outcome=preview_refused` and exit 0. They are **not** broker-redemption refusals.
   - **G12/G13/G14** (bad / replayed / stale receipt injection) and **G15** (a
     forbidden package argument to the nullary `apt.update` entrypoint) keep calling
     `rab-exercise` directly: they deliberately inject invalid, replayed, or stale
     receipts / arguments that the pkgops issuer would never construct, so only the
     lower-level oracle can express them.
   - **G11a/G11b** invoke `pkexec` directly (the entrypoint-isolation checks), below
     both pkgops and rab-exercise.

   `apt-issue` **recomputes** the preview itself and compares the caller-supplied
   resource / plan_hash byte-for-byte before committing — it never trusts caller hash
   data, and no receipt or binding ever enters argv/env/disk/output.
   `polkit-matrix.sh` is **unchanged** — pkgops does not move the polkit boundary.

### 4.3 The public path proven

For each gate: `apt_<verb>_preview(...)` (the unprivileged planner, as `aptbot`) →
`apt_<verb>(preview)` → capability query → polkit (§4.4) → native effect-session
open → real `pkexec` entrypoint under `/usr/libexec/pkgexec/` → strict result
parse → `pkgstate` verification → `write_outcome` to the real broker at
`/run/runix-audit.sock` → durable line in `/var/log/runix/audit.jsonl`.

---

## 5. Evidence requirements — what "pass" means

Captured to a fresh `~/canary-apt/evidence-<ts>-<pid>/` on the host (never
committed; the per-run dir is disposable). Pass = **all** of:

1. **`polkit-matrix.sh`: 23/23** — unchanged from the pkgexec proof (pkgops does
   not touch the polkit boundary). A regression here means the harness/stack is
   mis-built, not a pkgops finding.
2. **`apt-gates.sh`: 37/37.** The **functional gates** run through the real pkgops
   issuer (`apt-issue`); each gate's status / `effect_issued` / dpkg post-state
   assertion holds with pkgops as the issuer (G1 update, G3/G4/G5
   install/remove/upgrade, G6/G7 dpkg_broken, G8 hold/unhold, G9 protected, G-OWN
   not-owned, G10 apt_locked, G-INT interrupted, G-INLINE, G-PREV-*). G9/G-OWN are
   pkgops **preview-side** refusals (no intent opened), not broker-redemption
   refusals. The remaining gates stay on the lower-level oracles by design: **G12-G14**
   (bad / replayed / stale receipt injection) and **G15** (forbidden package arg to
   the nullary `apt.update` entrypoint) call `rab-exercise` directly, and **G11a/G11b**
   (entrypoint isolation) call `pkexec` directly — pkgops would never construct the
   invalid receipts / arguments those gates inject.
3. **NEW — durable-record round-trip.** For the success gates, the outcome line in
   `audit.jsonl` (via `redact.jq`) must:
   - be **accepted by the real broker** — every field on the allow-list with the
     correct type (`observed` an object, `changed`/`state_changed` scalar booleans,
     etc. per §2.1) — proving the record pkgops builds is not a `schema_invalid`
     against the shipped `RECORD_SCHEMA` (the exact thing hermetic tests cannot
     prove, since the R side never enforces the positive allow-list);
   - carry the §2.2 field set with values matching pkgops's verdict: `observed`
     holds the real per-package dpkg post-state in the §2.4 shape, `changed`
     reflects the verification verdict, `state_changed` the D7 rule,
     `observed_failed` false, `authorized_via` the §2.5 provenance for the branch
     taken;
   - contain **no** non-allow-list field and **no** reserved key (proving pkgops's
     record-field constant matches the broker's real allow-list). pkgops's
     `observed` is **richer** than `rab-exercise`'s `{status,detail}` placeholder,
     so this is an acceptance + value-correctness check, **not** byte-equality with
     the oracle;
   - **NEW negative gate:** a deliberately mis-named field in the record must be
     rejected by the real broker as `schema_invalid` (proving the hard-reject path
     and that pkgops fails closed on a bad record rather than silently dropping it).
4. **A verification-mismatch gate.** Force a post-state that disagrees with the
   plan (e.g. a maintainer script that leaves a different version) and assert the
   durable line shows `changed=false` + `observed_reason` set + the commit still
   **written** (verification failure is captured, never raised — the 5b invariant,
   now proven end to end).
5. **No temp polkit grant survives** (the harness already asserts this) and the
   guest dpkg state matches expectations (`dpkg-state.txt`).

The committed proof is the **pass counts in the runbook + roadmap** (as the pkgexec
proof recorded "23/23 polkit matrix, 37/37 §7 gates"); this increment adds the
durable-record assertion count, e.g. "23/23 + 37/37 through pkgops + N/N
durable-record round-trip." (Note: the authoritative committed figures are
**23/23** and **37/37**; there is no "68/68" in the repos.)

---

## 6. Teardown procedure

`deploy/canary/provision.sh destroy`, on the KVM host:

- refuses an empty/ambiguous domain name and refuses any same-named domain lacking
  the ownership marker `runix-canary owned by deploy/canary/provision.sh`;
- `virsh destroy` + `undefine --remove-all-storage`, `vol-delete` the qcow2 + the
  cloud-init seed, then **asserts** the domain and volumes are actually gone;
- never removes the shared NAT network or any other domain.

Guardrails, restated: the destructive run happens **only in the disposable KVM
guest**, never on the **troy-g5 host** (per the standing rule — do not touch the
host's NVIDIA / kernel / boot / networking / SSH / container-runtime). The guest is
cattle: re-provisioning tears down and rebuilds from the pinned, checksum-verified
Ubuntu 24.04 base image, not a trusted snapshot. `apt-gates.sh` refuses to start on
a stale temp grant / G5 pin / inline source.

---

## 7. Sequencing (how PR #9 lands)

1. **Part A** merges to master on hermetic review (safe: #9 still held, so master
   is not mutation-capable).
2. #9 is rebased onto master (picking up Part A's enriched record).
3. The harness edits (§4.2) land in `runix/deploy/canary-apt/` on review.
4. **Part B**: run the disposable-VM proof against the #9+PartA stack. Capture
   evidence. Iterate on any real-broker/real-dpkg finding (the VM is where the
   broker-lifecycle field values and the allow-list/type match get proven against
   the shipped `RECORD_SCHEMA`).
5. On green evidence (§5), **merge #9** and record the pass counts in the runbook +
   roadmap. Master is now mutation-capable with a proven durable record.
6. Then slice 4: `rctl apt.*` (separate).

---

## 8. Decisions

**Approved (this round):** D1 (map into the existing allow-list, no schema bump),
D2 (enrich `.verify()` with observed + mismatch/read-failure), D3 (merge Part A
first with #9 held), D4 (harness edits as their own reviewed commit). D5
(conditional): after Part A and the harness commit are separately reviewed and
green, drive Part B on a freshly provisioned disposable troy-g5 guest; no host
mutation; no provisioning before that final go; preserve redacted evidence +
independent teardown verification.

**Resolved this round:**

- **(D6) APPROVED.** `authorized_via` (§2.5): `"autonomous"` labels a machine-mode
  `rc=0` authorization of an autonomous-class verb (`update`/`hold`), identifying
  the authorization **class**, not the exact polkit rule (`pkcheck` does not reveal
  the rule). Caveat stated in §2.5.
- **(D7) = S-B.** `state_changed` is the **observed** pre/post `pkgstate` diff
  (§2.2/§2.3), not derived from `effect_issued` — an issued effect (or an
  `operation_failed` / `dpkg_broken` that began) need not have changed the relevant
  state, so an `effect_issued`-derived `state_changed` would mislabel the audit.
  Part A adds a pre-commit snapshot and compares it with the post-state;
  `state_changed = null` whenever either side is unavailable (§3 step 2).

With D6 + D7 resolved, the two shapes are fixed in §2.4 (`observed`) and §2.1/§2.2
(`changed`/`state_changed` as scalar booleans), and **Part A is
implementation-ready**. PR #9 and VM activity remain held.
