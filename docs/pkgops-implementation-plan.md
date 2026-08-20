# pkgops: implementation plan (build sequence)

**Companion to `pkgops-plan.md`** (the contract, merged #70). That doc settled the
*what* (§10: "no further broad design round"). This doc is the *how*: the slice
order, concrete C/R signatures, file layouts, and the test ladder, specified
against the **actual v0.0.3 pkgexec wire contracts and runix C scaffolding** as
they exist today. No code lands until this is signed off.

Nothing here reopens a settled contract decision. Where this doc diverges from the
contract it is only to **correct the contract against the shipped source** (§0).

**Rev 2 (post-review):** the six sign-off questions are resolved (§8), and nine review
corrections are folded into slices 2–3 (§8 tail) — shared byte-level transport with
parse-and-wipe before any R object, `posix_spawn` over `fork`, verb-not-path with a C-owned
entrypoint map, a real effect-receipt capability query, helper-authoritative `effect_issued`,
outcome-closed-before-signal, `pkgstate` as an `Imports`, runix-owned struct bounds, and
Jansson linked in the C core. Slice 1 has landed (pkgstate #10); slice 2 begins against this
revised plan.

---

## 0. Corrections to the contract, from the shipped pkgexec v0.0.3

The contract's §6.1 record grammar predates the merged pkgexec planner slice and is
wrong in five places. The implementation follows the source; `pkgops-plan.md` §6.1
should be patched to match (a docs-only change, listed in §7 below).

| contract §6.1 says | shipped source emits | cite |
|---|---|---|
| configure record field `dpkg_state` | `state` | `preview.cc:159`, `digest.h:40` |
| txn record fields `owned, protected, held` | no such fields; `flags[]` with vocab `{hold, auto, essential, protected}`; **no `owned` flag exists** | `apt_common.cc:66-79`, `digest.h:32-36` |
| planner at `/usr/libexec/...` | `runix-apt-preview` at **`/usr/bin`** (on PATH) | `Makefile:264`, CI `ci.yaml:103` |
| result status set implied uniform | preview emits **9** statuses, the commit channel emits **12** (adds `apt_locked`, `no_intent`, `not_applied`, `operation_failed`) | `preview.cc:33-34`, `result.c:11-39` |
| §4.5 "anonymous stdin pipe" for the receipt | receipt travels **inside the stdin JSON request** on fd 0 (the pkexec pipe), not a separate fd | `entrypoint.c:70-76` |

The exact grammars both slices build against are pinned in Appendix A.

---

## 1. Build order

Four slices, each its own reviewed PR. Dependency edges force the order only
between 2→3 and 3→4; slice 1 is independent and lands first as the low-risk warmup.

```
slice 1  pkgstate::dpkg_selections()        [DONE — pkgstate #10, 0.0.1.9]
slice 2  runix native effect-session API    [C in common core; critical-path enabler]
slice 3  pkgops package                      [needs 1 + 2]
slice 4  rctl apt.* surface                  [DONE — rctl #12, 0.0.1.8]
```

- **Slice 1** unblocks hold/unhold verification and touches nothing risky. Good
  first landing, proves the pattern, no VM/sudo.
- **Slice 2** is the security-critical piece and the enabler for everything downstream.
  Its own careful PR with the fake-server tests below.
- **Slice 3** is the package itself; it can only be exercised once 2 exists, but its
  preview half (slice 3a) only needs the planner binary and can be built/tested against
  a fake before 2 lands, so 3 splits into 3a (preview) and 3b (commit lifecycle).
- **Slice 4** waits until the R API is stable, exactly as contract §8 requires.

---

## 2. Slice 1 — `pkgstate::dpkg_selections()`

The one new read-only accessor the contract (§6.3, §8) calls for. Mirrors
`dpkg_installed()` line for line: same runner, same `dpkg-query -W` mechanism, pure
parser split from IO, offline fixture test.

**Signature**

```r
dpkg_selections(packages = NULL) -> data.frame(package, architecture, selection)
```

- Reads the dpkg *want* field (the selection), not the status word:
  `dpkg-query -W -f='${Package}\t${Architecture}\t${db:Status-Want}\n'`.
- `selection` ∈ `{install, hold, deinstall, purge, unknown}` (dpkg's want vocabulary).
- `packages = NULL` returns every entry; a character vector filters to those names
  (matching the `apt_origins(pos)` / `apt_candidates(pos)` family that already takes
  targets).
- Pure parser `parse_dpkg_selections()` fails closed on any line that is not exactly
  3 tab-separated fields (same rule as `parse_dpkg_w`).

**Verification use (in pkgops, slice 3):** after `hold`, each changed target must read
back `selection == "hold"`; after `unhold`, `selection == "install"` (contract §6.3).

**Tests:** offline fixture of `dpkg-query` output (install/hold/deinstall/purge/unknown
rows, a multiarch pair) + an `at_home` live smoke asserting a known-held package (or
skips if none held). No new dependency; pkgstate stays read-only.

---

## 3. Slice 2 — runix native effect-session API

C in the common core. Holds the broker receipt **and** the outcome binding in
wipeable heap, spawns the pkexec entrypoint natively via `posix_spawn`, and runs the
contract's state machine. Reuses a **refactored byte-level transport** under
`C_rab_broker_call` (§3.4) and the existing deadline/poll/peercred helpers rather than
duplicating socket code; links `libjansson` for in-C extraction; introduces the
package's first `EXTPTRSXP` handle and first `explicit_bzero`.

### 3.1 Why native, restated in one line
Today `open_intent` returns the receipt to R as a `^[0-9a-f]{32}$` **CHARSXP** the GC
retains and copies (`audit_broker_sink.R:270-282`). The session removes that: the
receipt and binding are extracted from the broker response **in C** and never become R
objects.

### 3.2 The handle (C)

```c
typedef enum { ES_OPENED, ES_RECEIPT_SENT, ES_RESULT_KNOWN,
               ES_EFFECT_UNKNOWN, ES_OUTCOME_ATTEMPTED, ES_CLOSED } es_state;

typedef struct {
    pid_t     owner_pid;         /* PID binding; every call re-checks getpid() */
    es_state  state;
    unsigned char *receipt;      /* 32 hex, wipeable heap; explicit_bzero on wipe   */
    unsigned char *binding;      /* 32 hex, wipeable heap; for write_outcome         */
    char      correlation_id[38];/* sanitized, R-exposable (20d '-' 16h + NUL)       */
    int       verb;              /* a runix-owned closed verb enum, not a path       */
    char      resource[RUNIX_APT_RES_CAP];
    char      plan_hash[65];
    int       plan_schema;
} runix_effect_session;
```

All bounds are **runix-owned contract constants** (`RUNIX_APT_RES_CAP`, `RUNIX_RECEIPT_HEXLEN`,
etc.), never borrowed pkgexec-private `PKGX_*` names — the two repos version independently.
Wrapped as an `EXTPTRSXP` tagged with `install("runix_effect_session")`, protected by
`R_RegisterCFinalizerEx(handle, es_finalize, TRUE)`. `verb` is a runix enum over the nine
contracted verbs; the C side maps it to the immutable entrypoint path (§3.4), so **no path
ever crosses from R**.

### 3.3 `.Call` entry points (register in `rab_call_methods[]`, un-prefixed name → `C_` in R)

| C name | arity | transition | does |
|---|---|---|---|
| `effect_session_open` | 7 | → `ES_OPENED` | broker `open_intent(operation, resource, effect={plan_schema, plan_hash})` over the **shared byte-level transport** (§3.4); extract `effect_receipt` + `binding` + `correlation_id` from the response with **linked Jansson, in C**, into wipeable heap; return `list(handle, correlation_id, status)` — the receipt/binding never become R objects |
| `effect_session_commit` | 4 | `ES_OPENED`→`ES_RECEIPT_SENT`→`ES_RESULT_KNOWN`/`ES_EFFECT_UNKNOWN` | takes the **verb enum, never a path**; C maps it to the immutable `/usr/libexec/pkgexec/runix-apt-<verb>`; `posix_spawn` of `pkexec <that path>` (no shell); build the commit request JSON **in C wipeable heap** (`{effect_receipt, correlation_id, plan_schema, packages[], lock_timeout}`), write to child stdin, `explicit_bzero` request + receipt; read the sanitized result frame; return the raw result body (no secret) to R |
| `effect_session_write_outcome` | 3 | →`ES_OUTCOME_ATTEMPTED`→`ES_CLOSED` | broker `write_outcome` using the held `binding`; `explicit_bzero` binding; return `list(status)` |
| `effect_session_state` | 1 | — | inspection for tests/asserts |

One-shot enforcement: each call checks `owner_pid == getpid()` (a `fork`ed or
`unserialize`d handle mismatches → refuse) and the exact expected `state` (re-use → refuse).
The verb→path map is the only source of entrypoint paths; the fake entrypoint is
substituted for unit tests through a **compile-time, test-binary-only seam** (`#ifdef
RUNIX_TESTING`, absent from the production build). **No runtime environment variable may
ever redirect the entrypoint** — a substitutable path that gets `exec`'d under `pkexec` is a
root privilege-escalation surface, so the map is immutable in the shipped binary and
production R can never name a path. (This is stricter than the broker's
`RUNIX_ALLOW_TEST_SERVER` env seam, which only points at a fake *unprivileged* socket, never
a root exec.)

### 3.4 Custody + hygiene rules (match-or-exceed the existing floor)
- **The secret must never reach a RAWSXP.** Today `C_rab_broker_call` copies the whole
  broker response (which carries the receipt) into an R `RAWSXP` at `unix_socket.c:335`,
  GC-managed and unwipeable. Refactor: extract a **lower-level byte transport**
  (`rab_transport(path, req, len, out_buf, out_len, deadlines, uid)` operating on a
  `malloc` buffer) that both the existing R wrapper **and** the effect session call. The
  existing wrapper keeps its current behavior (copies the buffer to a RAWSXP for
  non-secret payloads); the session **parses and wipes the buffer before any R object is
  created**. One transport, two consumers, no duplicated socket code.
- **The generic R wrapper must *refuse* effect-bearing requests — not merely avoid them.**
  R can construct any request body, so an `open_intent` carrying an `effect` block could be
  sent through `C_rab_broker_call`'s R wrapper (`.broker_call` / the broker sink's
  `open_intent`) and come back with a receipt in a `RAWSXP`. The wrapper therefore
  **fails closed on any request whose body carries `effect`** (`runix_effect_via_generic_path`),
  so an effect-bearing intent is serviceable **only** through `effect_session_open`. This
  positive guard is what makes "the receipt never reaches R" a property of the API rather
  than a convention the caller could sidestep.
- **Extraction is linked Jansson, in C — not a hand-rolled scanner** (ruling Q4). Runix
  already depends on strict JSON semantics; link `libjansson` directly so `effect_receipt`
  / `binding` / `correlation_id` are pulled with dup-key rejection, exact schema, and
  proper string unescaping. Each value is then strictly re-validated
  (`effect_receipt`/`binding` = 32 lowercase hex; `correlation_id` = the cid shape).
  Off-pattern → fail closed, wipe, `ES_CLOSED`. **Build impact:** add `libjansson-dev` to
  runix build-deps and `libjansson4` at runtime, update `SystemRequirements`, the CI
  install step, and the eventual `.deb` control metadata (§7).
- Receipt/binding live only in `malloc`'d buffers wiped with **`explicit_bzero` before
  `free`**, and on the finalizer path. New in the package (nothing zeroes secrets today).
- Reuse `rab_now_ms`/`rab_wait`/`rab_read_all`/`rab_write_all` for all socket IO and the
  child result read, with absolute deadlines and the 64 KiB cap.
- **Spawn with `posix_spawn`, not `fork`.** A bare `fork` inside a live R process inherits
  R's signal handlers, allocator locks, and any threads into the child before `exec` — a
  known hazard. `posix_spawn` + `posix_spawn_file_actions` sets up the stdin pipe and the
  result fd, closes everything else, and `exec`s the **immutable** `pkexec <verb→path>`
  atomically. Absolute path, no shell; wall-clock deadline; `SIGPIPE`-safe stdin write.
- **Finalizer only wipes** (receipt, binding, buffers, fds). It never writes an outcome
  and never fabricates a result — a dropped handle leaves the intent open, which is the
  correct fail-closed state (contract §4.8).
- Only `correlation_id` and the parsed status are ever handed to R.

### 3.5 Conditions + retryability
- New subclasses raised via `runix_abort(subclass = …)` (runix has no class registry;
  the subclass string *is* the taxonomy): `runix_helper_bad_result`,
  `runix_preview_failed`, `runix_verification_failed`, `runix_capability_unavailable`,
  `runix_unauthorized`, `runix_approval_required`.
- **Retryability is registered by owner and phase, and means *definitely no effect*
  happened** (ruling Q3). A retry is only safe when the operation provably did not touch
  the host:
  - `apt_locked` (lock contention, refused **before** commit → no effect) is
    apt-specific and registered in **`pkgops`'s `.onLoad`**, not runix's.
  - runix registers only classes it *owns*; it does **not** add a load hook just for
    these, so there is no new runix `zzz.R` on this account.
  - **Generic transport/timeout errors are NOT retryable.** An outcome timeout *after* the
    receipt was delivered leaves the effect state genuinely unknown — retrying could
    double-apply. Those stay `runix_helper_bad_result` / effect-unknown (`NA`), intent
    left open, never auto-retried.

### 3.6 Effect-receipt capability query (a real negotiation, not just peer auth)
`runix::broker_available()` only authenticates the peer (SO_PEERCRED) and confirms the
socket answers; it does **not** establish that the broker speaks the effect-receipt
extension at the plan schema pkgops needs. Add an exported
`runix::effect_capability(socket_path, plan_schema = 1)` that sends the broker's
capability query and checks the reply advertises the **effect-receipt extension** and the
required **plan schema** before any intent is opened. Absent extension / wrong schema /
unreachable → `runix_capability_unavailable`, fail closed, nothing minted. `broker_available`
stays as the cheap liveness probe; this is the contract-compatibility gate on top of it.

### 3.7 Tests (no root, no dpkg)
- Reuse the in-tree fake broker server (`C_rab_test_serve_once`, gated by
  `RUNIX_ALLOW_TEST_SERVER`) to script `open_intent`/`write_outcome` replies.
- A **fake entrypoint** (a tiny script the session `execve`s) that reads the stdin
  request and emits a chosen result frame — drives every result status and the
  effect-unknown path.
- State-machine assertions: re-use refused, `fork`ed-handle refused, `unserialize`d-handle
  refused, finalizer-wipes-without-outcome, receipt/binding never appear in any R value
  (inspect with a serialization/`gc` probe).

---

## 4. Slice 3 — the `pkgops` package

New sibling repo `cornball-ai/pkgops`, `pkgKitten` skeleton,
`Imports: runix, janssonr, pkgstate`, `Suggests: tinytest`. **pkgstate is an `Imports`,
not a `Suggests`** (correction): verification (§4.5) is mandatory, not optional, so the
dependency is honest — an issuer that can't read post-state can't close an outcome
truthfully. Version starts `0.0.1`. Splits into 3a (preview, buildable against the planner
binary alone) and 3b (commit lifecycle, needs slice 2).

### 4.1 Per-verb R API (contract §5)

```r
p   <- pkgops::apt_install_preview(c("nginx"))       # -> pkgops_preview (advisory)
out <- pkgops::apt_install(p, lock_timeout = 300)     # commits only p's {verb,resource,hash}
```

Generated for the nine verbs. `apt_<verb>(preview, …)` refuses a preview whose
`{verb, resource, plan_hash}` it did not produce, and a verb/preview mismatch. The
combined `apt_<verb>_run()` is defined in terms of the two-call form (no second path).

### 4.2 Preview (slice 3a)
- Spawn `/usr/bin/runix-apt-preview` via a runix runner; strict stdin request
  `{schema_version:1, verb, packages}` (Appendix A.1). Per-verb arity enforced in R
  before spawn (targets only for install/remove/purge/hold/unhold).
- Parse the one uniform stdout JSON (Appendix A.2) with janssonr, strict. Map **all nine**
  planner statuses: `ok` → a `pkgops_preview`; `no_op` → a typed no-op (**no intent
  opened**); `schema_invalid`/`resolve_failed`/`internal`, the policy refusals
  (`package_not_owned`/`held`/`protected_package`), **and `dpkg_broken`** (a pre-existing
  broken dpkg state the preview surfaces — `runix_dpkg_broken`, no intent) → typed
  conditions. Stop here on anything non-`ok`. (The earlier draft omitted `dpkg_broken`
  from the preview set; the planner can emit it.)
- Records carried verbatim (verb-specific, Appendix A.2) into `pkgops_preview$records`;
  the original validated `packages[]` echoed back, never reconstructed from `resource`.

### 4.3 Commit lifecycle (slice 3b)
Follows the contract's branched flow (§4). In order:
1. **Effect-receipt capability query** (`runix::effect_capability`, §3.6) — the real
   extension+plan-schema negotiation, not just `broker_available`'s peer auth;
   absent/unreachable/wrong-schema → fail closed, nothing invoked.
2. Polkit branch (§4.4 of the contract): machine mode → native `pkcheck`; a
   denial/would-interact opens a **plain intent** (no receipt) + terminal outcome
   (`approval_required`/`unauthorized`), stop. Autonomous `update`/`hold` proceed only when
   already authorized. Interactive → the `pkexec` prompt happens during the entrypoint spawn.
3. `runix::effect_session_open(...)` → handle (§3.3).
4. `runix::effect_session_commit(handle, verb, packages, lock_timeout)` → raw result. The
   **verb (not a path)** is passed; C maps it to the immutable entrypoint (§3.3/§3.4).
5. Strict parse of the result (Appendix A.3), cid-equality check; map the **12-status**
   commit vocabulary through the closed table in §4.4 → typed condition. Read
   `effect_issued` **from the helper's boolean**, authoritative (§4.4).
6. `pkgstate` verification (§4.5) per resolved record (skipped only when the status made
   no state claim). A verification **failure is captured into the outcome, not raised** — a
   clean helper status with a disagreeing post-state is a failed outcome that still gets
   written, never an exception that skips step 7.
7. `runix::effect_session_write_outcome(handle, outcome)`.
8. **Only now return or signal.** A strict parseable failure status (`operation_failed`,
   `dpkg_broken`, `no_intent`, …) **and** a verification failure are both *known truth* that
   **must close the outcome first** (contract §4.8): the order is always parse → verify →
   **attempt outcome** → *then* return/signal the `pkgops_outcome`. **No R exception raised
   in steps 5–6 may bypass the outcome attempt** — those steps run inside a handler that, on
   any error, still attempts `write_outcome` in step 7 and only then re-signals the
   condition. The intent is left open **only** for genuine effect-unknown
   (`runix_helper_bad_result`, process death, or a failed outcome persist), never because a
   parse/verify error short-circuited the close.

The verb→entrypoint map (`/usr/libexec/pkgexec/runix-apt-<verb>`, `dist_upgrade` →
`dist-upgrade` binary) lives in C (§3.4), not R.

### 4.4 The closed status→condition mapping (commit channel, 12 values)

Mirror of `pkgexec` `result.c:11-39` (Appendix A.3); pinned by a test that reproduces the
same 12 rows, so the two never drift.

**`effect_issued` is NOT a function of `status`** (correction). It is the helper's own
first-class boolean (`result.c:57`) and is read verbatim — the mapping table only assigns
the *condition*. `dpkg_broken`, in particular, can carry `effect_issued` **true or false**
(`pkgexec/tests/test_result.c:95`): a broken dpkg found pre-commit vs a commit that broke
it are different truths the helper distinguishes and pkgops must not overwrite. `NA` is
**reserved** for effect-unknown (malformed/lost result, process death) — never synthesized
from a status.

| status | condition | retryable (definitely-no-effect only) |
|---|---|---|
| `ok` | success | — |
| `no_op` | success, empty | — |
| `apt_locked` | `runix_apt_locked` (refused pre-commit) | **yes** (pkgops-owned, §3.5) |
| `package_not_owned` | `runix_not_owned` | — |
| `held` | `runix_held` | — |
| `protected_package` | `runix_protected` | — |
| `no_intent` | `runix_no_intent` (drift/replay/expiry; `detail` carries reason) | — |
| `resolve_failed` | `runix_resolve_failed` | — |
| `not_applied` | `runix_not_applied` | — |
| `operation_failed` | `runix_operation_failed` | — |
| `dpkg_broken` | `runix_dpkg_broken` | — |
| `internal` | `runix_helper_internal` | — |

Every row above is a **known result → the outcome is closed** with the helper's reported
`effect_issued` (contract §4.8, and §4.3 step 8). Only a malformed/short/dup-key/cid-mismatch
result is `runix_helper_bad_result` → effect-unknown (`NA`), intent left open.

### 4.5 Verification (contract §6.3), read through pkgstate
- install/remove/purge/upgrade/dist_upgrade/configure: `pkgstate::dpkg_installed()` covers
  presence, version, incomplete-state; each **resolved record** checked to its planned
  post-state (not only the requested targets).
- hold/unhold: `pkgstate::dpkg_selections()` (slice 1); targets read back in the intended
  selection.
- update: no pkgstate postcondition → `verified = NA`.

### 4.6 Result schemas
`pkgops_preview` / `pkgops_outcome` exactly as contract §6.1/§6.2, built on runix's result
shell, with the §0 record-field corrections applied.

### 4.7 Tests (fakes; no root, no dpkg — contract §9)
Fake planner (canned preview JSON per status), fake broker transport, fake entrypoint,
the native-session state machine (from slice 2), pkgstate fixtures. Vendor the pkgexec
`tests/fixtures/broker-frames/*.json` (7 files, source-only, not installed) and mirror the
12-row status table so drift is a failing test.

---

## 5. Slice 4 — rctl `apt.*` surface (last)

Mirrors the `host.*`/`packages.*` pattern just landed. pkgops is a runtime-detected
`Suggests`. Verbs: `apt.<verb>-preview` (read-only-ish; opens no intent) and `apt.<verb>`
(the mutation; `mut("pkgops", …)`), machine mode surfacing `approval_required` as the
contract's terminal envelope. Advertised via `rctl capabilities`. Built only once the R
API is stable.

**DONE (2026-08-20, rctl #12, rctl 0.0.1.8).** 18 operations (nine
`apt.<verb>-preview` + nine `apt.<verb>`) in `rctl/R/dispatch.R`, plus
`ERROR_PASSTHROUGH` widened for pkgops's `verb`/`plan_hash`/`status`/
`effect_issued`/`detail`. As-built refinements: authorization is **always machine
mode** (`interactive = FALSE`) — rctl runs non-interactively with no polkit agent,
so a denial or `approval_required` surfaces as a terminal exit-1 envelope, never a
prompt; `--preview` (the system-wide dry-run flag) returns the advisory and opens
no intent; and the apt handlers reference pkgops **lazily** (`getExportedValue`
inside the closure, not `mutation_handler`'s eager `force`) so `operations()` and
`capabilities` still build with pkgops absent. `apt.configure` is nullary
(whole-system set = update/upgrade/dist_upgrade/configure). 68 hermetic tests drive
real pkgops through its own faked seams; proven non-vacuous in CI (the CI also
gained `libjansson-dev` + `pkgops` in the sibling build). Hermetic-only proof, no
new VM run. **Slice 4 was the last slice; the arc is functionally complete.**

---

## 6. Verification ladder (contract §9) and what needs the VM

1. Contract (done) → 2. R API + schemas (this plan) → 3. **unit tests against fakes**
(every slice above; no root, no dpkg) → 4. **disposable-VM gate on troy-g5**, real
`pkgops` replacing `rab-exercise` as the issuer, the existing §7 gates run end to end.

**Blocked on you (not on the next step):**
- The end-to-end VM gate needs the troy-g5 canary (destructive; VM-only per the standing
  rule). Slices 1–3 all develop and unit-test with **no** VM/sudo/publish.
- **A0-release** (signed public apt archive) and tagging pkgexec 0.0.3 stay deferred —
  your call, not a blocker for building pkgops.

---

## 7. Docs + housekeeping riding with this arc
- **Slice 1 landed** as pkgstate PR #10 (`dpkg_selections()`), 0.0.1.9.
- **Jansson in the runix C core** (ruling Q4): add `libjansson-dev` build-dep + `libjansson4`
  runtime, update runix `SystemRequirements`, the r-ci install step, and the runix `.deb`
  control metadata when it is packaged. This is a real new native link, called out here so it
  is reviewed as part of slice 2, not smuggled in.
- Patch `pkgops-plan.md` §6.1 for the five §0 corrections (docs-only).
- Correct the `pkgops-plan.md` header: it still reads "plan only, and NOT approved" while the
  greenlight is given (Q1) and the prerequisite planner slice is merged — update it to
  approved. (Its own small docs commit on the runix repo; not folded into a code PR.)
- The apt-arc memory note is stale (it calls pkgexec #4 a draft with CP3 pending; #4 is
  merged, 0.0.3, VM parity passed). Update it to point at pkgops as the frontier.

---

## 8. Rulings (resolved in review)

All six sign-off questions are decided; recorded here so the slices inherit them.

- **R1. Greenlight: yes.** "Do pkgops" is the approval. Update the contract header (§7).
- **R2. Session handle: three-call form.** `open → commit → write_outcome` on one
  `EXTPTRSXP`, R doing the pkgstate verification between commit and outcome. A strict
  non-success result is recorded (outcome written) **before** its condition is signaled
  (§4.3 step 8).
- **R3. Retryability by owner and phase.** `pkgops::.onLoad` registers apt-specific
  definitely-no-effect retries (`apt_locked`); runix registers only core-owned classes and
  adds no load hook for this; generic transport/timeout is **not** retryable — retryability
  must imply *definitely no effect* (§3.5).
- **R4. Extraction: link Jansson.** No hand-rolled scanner; link `libjansson` in the runix C
  core, with the build/CI/SystemRequirements/`.deb` updates in §7 (§3.4).
- **R5. pkgops repo: yes.** Create public `cornball-ai/pkgops` at `0.0.1` when slice 3 starts.
- **R6. Cadence: yes.** Four reviewed PRs in dependency order; slice 3 may carry 3a/3b review
  checkpoints inside its single PR.

### Corrections folded in from review (beyond the six)
- Byte-level transport shared by the existing wrapper and the session; parse+wipe the
  secret-bearing response **before any R object** (no RAWSXP for the receipt) — §3.4.
- `posix_spawn`, not `fork`, inside the R process — §3.4.
- The session takes a **verb**, never a path; C owns the verb→immutable-entrypoint map; a
  test-only seam supplies the fake — §3.3/§3.4.
- A real **effect-receipt capability query** (extension + plan schema), not just
  `broker_available` — §3.6.
- `effect_issued` is the helper's authoritative boolean, not per-status; `dpkg_broken` can be
  either; `NA` only for lost/malformed — §4.4.
- Outcome is closed **before** any failure condition is signaled — §4.3 step 8.
- `pkgstate` is an `Imports` of pkgops (verification is mandatory), not a `Suggests` — §4.
- runix-owned struct bounds (`RUNIX_APT_RES_CAP`, …), never pkgexec-private `PKGX_*` — §3.2.
- Preview status mapping includes `dpkg_broken` — §4.2.

### Review round 2 (PR #73)
- The generic `C_rab_broker_call` R wrapper **rejects effect-bearing requests**
  (`runix_effect_via_generic_path`), so a receipt can never return through the RAWSXP path —
  it is not enough that the session avoids it — §3.4.
- The fake-entrypoint seam is **compile-time / test-binary-only** (`#ifdef RUNIX_TESTING`);
  **no runtime env var** may redirect a root-`exec`'d entrypoint path — §3.3.
- A **verification failure** also closes the outcome first: steps 5–6 run inside a handler
  so no parse/verify exception bypasses `write_outcome` — §4.3 steps 6, 8.

---

## Appendix A — pinned wire contracts (pkgexec v0.0.3, quoted from source)

### A.1 `runix-apt-preview` request (`request.c:384-466`)
`{"schema_version":1,"verb":"apt.<verb>","packages":[…]}` — strict: dup-key/trailing/
unknown-member/missing/depth>4/NUL rejected. Arity: `packages` empty for
`update`/`configure`/`upgrade`/`dist_upgrade`; non-empty for
`install`/`remove`/`purge`/`hold`/`unhold`. Names strict Debian, ≤256, dups rejected.

### A.2 `runix-apt-preview` response (`preview.cc:188-225`)
`{schema_version:1, status, verb, packages[], plan_schema, resource, plan_hash, records[],
detail}`. `plan_hash` (64 hex) present **only** for `ok`/`package_not_owned`/`held`/
`protected_package`; else `null`. Statuses (9): `ok, no_op, schema_invalid, resolve_failed,
package_not_owned, held, protected_package, dpkg_broken, internal`. Exit 0 iff `ok`/`no_op`.
Records per family (canonical, pre-sorted):
- txn: `{package, architecture, action∈{install,remove,purge,upgrade,downgrade},
  from_version, to_version, flags[]⊆{hold,auto,essential,protected}}`
- hold: `{package, from_state∈{install,hold}, to_state∈{hold,install}}`
- configure: `{package, architecture, current_version, state∈{unpacked,half-configured}}`
- update: `{uri, suite, components[], options{signed-by|architectures|trusted}}`
  (inline `signed-by` → `inline-sha256:<hex>`)

### A.3 entrypoint request + result (`request.c:246-354`, `result.c:41-78`)
- Commit request (stdin, fd 0): `{effect_receipt:<32 lc hex>, correlation_id:<20d-16h>,
  plan_schema:1, packages[], lock_timeout∈[0,3600]}`. Verb is the binary's compile-time
  constant, **not** in the request. Body `explicit_bzero`'d after parse.
- Result: `{status, effect_issued:<bool>, correlation_id, detail}` (4 keys, that order;
  detail ≤128). Written to a dedicated CLOEXEC fd; fd 1 pre-redirected to stderr. Exit 0
  iff `ok`/`no_op`. Statuses (12): the 9 above minus `schema_invalid`, plus `apt_locked,
  no_intent, not_applied, operation_failed`.
- Redeem (entrypoint→broker): `{type:"redeem_receipt", effect_receipt, principal_uid,
  effect:{operation, resource, plan_schema, plan_hash}}`; any non-OK →
  `no_intent` with `detail` = broker code (`receipt_mismatch`=drift, `receipt_redeemed`=
  replay, `receipt_actor_mismatch`, `receipt_expired`, …) / `cid_mismatch` / `transport`.

### A.4 install paths
`runix-apt-preview` → `/usr/bin/runix-apt-preview`. Entrypoints →
`/usr/libexec/pkgexec/runix-apt-{install,remove,purge,upgrade,dist-upgrade,update,hold,
unhold,configure}`. Digest golden → `/usr/share/doc/pkgexec/plan-digest-vectors.json.gz`.
