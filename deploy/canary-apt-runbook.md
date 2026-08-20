# Canary apt — pkgexec mutation boundary on a real systemd/polkit host

Status: runbook (executable). This is the **destructive VM gate** for two slices:
the pkgexec activation slice (`libapt-pkg-helper-plan.md` §7, contract conformance
14–21) — the apt-mutation effector (nine root entrypoints + polkit + broker
effect-receipts) on a real host — and the **pkgops VM-gate increment** Part B
(`docs/pkgops-vm-gate-plan.md`), which drives the functional §7 gates through the
REAL pkgops issuer and asserts the Part A durable-record round-trip. It extends the
A1 canary harness (`deploy/canary/`, same disposable KVM guest, same
ownership-marked teardown); the KVM host's
NVIDIA/kernel/boot/networking/SSH/container-runtime are never touched.

## Scope, stated honestly

The R stack **is** installed in the guest (R 4.6 + `janssonr` + `pkgstate` + `runix`
+ `pkgops`, from pinned staged sources), and the **functional** §7 gates run through
the real pkgops public path via the VM-only launcher `apt-issue` (`apt-issue.sh` →
`apt-issue.R`, calling `pkgops::apt_<verb>(apt_<verb>_preview(...))`). So this proves
the full public path end to end: preview → capability query → polkit → native
effect-session → real `pkexec` entrypoint → `pkgstate` verification → durable outcome
at the real broker.

`rab-exercise` is **retained** as the VM-only lower-level oracle for the gates the
pkgops issuer cannot express, because they deliberately feed the boundary inputs a
correct issuer would never construct: **G12/G13/G14** (a mismatched / replayed /
drifted receipt) and **G15** (a package argument to the nullary `apt.update`
entrypoint). **G11a/G11b** call `pkexec` directly (entrypoint-isolation, below both
pkgops and rab-exercise). Everything else is pkgops.

## The issue-time planner and the VM-only lifecycle oracle

- **`runix-apt-preview`** (pkgexec, **packaged**, run unprivileged as `aptbot`): the
  PRODUCTION planner — exactly the binary `pkgops` will call. Read-only and lockless,
  it produces the issue-time `resource` + `plan_hash` for a verb from one strict JSON
  request `{schema_version, verb, packages}`, reusing the effectors' shared
  `apt_common` descriptor builders and `pkgx_digest_*`, so a matching cache yields the
  matching hash. Nine closed statuses; exit 0 iff `ok`/`no_op`; a policy refusal
  carries the full records + hash + offender; a `no_op` carries no hash. The harness
  STRICTLY validates every preview response against the whole contract BEFORE it trusts
  the hash to `rab-exercise`: schema, the closed status set, the EXACT nine-key object
  (a missing key is rejected as firmly as an extra one), verb + packages echoing the
  request, per-verb record schema, a plan digest PINNED to the status (present for
  `ok`/`package_not_owned`/`held`/`protected_package`, absent otherwise), and exit 0
  iff `ok`/`no_op`. An invalid response HARD-STOPS the run before any redemption (see
  G-NEG). Successful receipt redemption from a valid hash is the parity proof: the
  advisory preview matched the effector's atomic locked re-resolution. Installed from
  the pkgexec `.deb` (on PATH at `/usr/bin`); the root `pkgexec-plan` diagnostic is no
  longer used by the gates.
- **`apt-issue`** (`apt-issue.sh` → `apt-issue.R`, VM-only, run unprivileged as the
  principal): the pkgops issuer launcher for the **functional** gates. It RECOMPUTES
  the preview itself via `pkgops::apt_<verb>_preview()`, treats the caller-supplied
  `resource`/`plan_hash` as EXPECTED values compared byte-for-byte before any commit
  (never trusting caller hash data), then calls `pkgops::apt_<verb>(preview)` and
  prints ONE `RESULT` line in the rab-exercise grammar with matching exit codes
  (0 persisted / 1 pre-intent / 3 left-open). No receipt or binding ever enters
  argv/env/disk/output — pkgops keeps those in the runix C heap and wipes them.
  Preview-side refusals (`package_not_owned`/`protected_package`, ...) are emitted
  with `effect_issued=false` / `outcome=preview_refused`, exit 0 (no intent opened).
- **`rab-exercise`** (broker `tools/rab-exercise.c`, run as the principal): the
  lower-level lifecycle oracle, now used only by the injection gates (G12-G15) — the
  whole lifecycle in ONE process (the outcome binding is pinned to the opener's
  full process identity). Verifies the broker peer is uid 0; `open_intent(+effect)`;
  hands the receipt to the exact pkexec'd entrypoint over a private stdin pipe;
  strictly validates the result; writes exactly one outcome; wipes both tokens;
  prints only non-secret evidence. `--replay` (update only) re-presents a redeemed
  receipt to prove single-use at the boundary. Any failure after the durable intent
  leaves it open for reconciliation.

`runix-apt-preview` is built + run in CI (a link gate plus an emit smoke) and ships in
the `.deb`; `rab-exercise` is compiled+linked in CI as the mutation-path proof and its
runtime is VM-only.

## In-guest fixtures

- `aptbot` (uid 1002): the **autonomous** principal, enrolled in
  `runix-apt-autonomous` (may run only `apt.update` and `apt.hold` non-interactively).
- `aptuser` (uid 1003): a **non-member** (the negative-authorization case).
- A local, trusted apt repo (`/srv/canary-repo`) with harmless packages:
  `canary-benign` (1.0/1.1: install/remove/upgrade/hold); `canary-badpost`
  (postinst exits 1, deps satisfied → half-configured → `dpkg_broken`);
  `canary-slow` (postinst sleeps → a catchable SIGKILL window for the interrupted
  transaction); `canary-protected` (`Priority: required` → protected-removal
  refusal — the contracted protected set, not broadened to `important`);
  `r-cornball-canary` (matches rapt's `^r-[a-z]+-[a-z0-9.]+$` → the ownership
  `package_not_owned` refusal).
- A second, GPG-signed flat repo (`/srv/canary-signed`) whose deb822 source carries an
  **inline armored public key** (not a keyring path), staged out of `sources.list.d`.
  The `signed-by` normalization gate (G-INLINE) adds it, proves the preview maps the
  inline key to `inline-sha256:<hex>` (never leaking armor) and that the hash redeems
  through the locked update effector, then removes it.
- A `fcntl-lock` helper: apt's lock is an fcntl record lock, not a flock, so the
  contention gate uses a small fcntl (F_SETLK) write-lock holder that genuinely
  excludes the helper's `GetLock`.

## Acceptance

### Polkit matrix (`polkit-matrix.sh`, receipt-free — the five proofs)

1. non-member `aptuser` denied the autonomous verbs;
2. member `aptbot` allowed **only** `update` + `hold` (machine mode, no prompt);
3. member still denied `unhold` and every package-changing verb;
4. machine mode never prompts (bounded `pkcheck`/`pkexec`, no agent);
5. all nine entrypoint paths root-owned and not group/world-writable.

### §7 gates (`apt-gates.sh`)

| gate | expectation |
|---|---|
| G1 update good-source | `ok`, `effect_issued:true`, durable intent+outcome, actor `uid:1002` |
| G2 update bad-source | `operation_failed` (Error-Mode=any) |
| G3/G4/G5 install/remove/upgrade | `ok`; native dpkg post-state; (temp-grant, removed+verified) |
| G6 failed-postinst | `dpkg_broken`, `effect_issued:true`; native half-configured |
| G7 configure (still failing) | `dpkg_broken`, `effect_issued:true` |
| G8 hold (autonomous) / unhold (temp-grant) | `ok`; dpkg selection reads back `hold` then `install` |
| G9 protected removal | `protected_package`, `effect_issued:false`, still installed (pkgops **preview-side** refusal: `outcome=preview_refused`, no intent opened) |
| G-OWN rapt-owned refusal | `package_not_owned`, `effect_issued:false` (pkgops **preview-side** refusal, before any redeem) |
| G10 lock contention | `apt_locked` (fcntl F_SETLK holder excludes `GetLock`) |
| G11a missing receipt | schema refusal (`internal`), `effect_issued:false` |
| G11b invalid receipt | `no_intent`, `detail=receipt_invalid` |
| G12 mismatched receipt | `no_intent`, `detail=receipt_mismatch`, `effect_issued:false` |
| G13 replay | first `ok`; replay `rejected` (`receipt_redeemed`) |
| G14 plan drift | `no_intent`, `detail=receipt_mismatch` |
| G15 entrypoint isolation | a package arg to `update` is **rejected** (`internal`, no effect); nothing installed |
| G-INT interrupted transaction | SIGKILL mid-commit → `outcome=open`; redeemed-no-outcome intent + dpkg ground truth |
| G-INLINE update, inline-Signed-By source | preview record `signed-by=inline-sha256:<64hex>`, no armored key in evidence; that exact preview hash redeems through the locked update effector (`ok`, `effect_issued:true`) |
| G-NEG malformed preview (issuer-side) | a contract-violating preview (missing key, verb/records mismatch, status-mismatched digest, exit disagreement) HARD-STOPS `do_plan` with a nonzero exit and a tripwire `do_ex` never fires; a valid control proceeds |
| G-PREV-OWN preview refusal (issuer-side) | `runix-apt-preview` (aptbot) returns strict `package_not_owned` + nonzero exit; **no** `rab-exercise`; audit sink byte-identical (no intent opened) |
| G-PREV-NOOP preview no-op (issuer-side) | `runix-apt-preview` (aptbot) returns strict `no_op` + exit 0; **no** `rab-exercise`; audit sink byte-identical (no intent opened) |

HELD is documented as unit-tested only: apt's own resolver honors holds, so a
resolved transaction that changes a held package is impractical to produce through
libapt; the plan-layer `PKGX_PLAN_HELD` path is covered by `test_plan.c`. Ownership
and protection stand in for the policy-refusal-before-receipt property at the VM
level.

Gated verbs follow codex's rule: the default-denial matrix is proven first, then a
temporary guest-only rule grants `aptbot` **only** the needed action for one gate,
recorded and removed afterward.

Gated verbs follow codex's rule: the default-denial matrix is proven first, then a
temporary guest-only rule grants `aptbot` **only** the needed action for one gate,
recorded and removed+verified afterward — and `apt-gates.sh` refuses to start on top
of a stale grant.

## Reproduce

`build-and-stage.sh` refuses to run unless all **five** trees are clean (broker,
pkgexec, runix, pkgstate, pkgops), `git archive`s from exact commits (so what is
staged is exactly what is committed and reviewed — including the three R sources
installed in the guest), and ships SHA-256 sums the guest verifies before building.
The host is a required argument (no hardcoded default).

```
# on the workstation (repos committed + clean):
deploy/canary-apt/build-and-stage.sh <kvm-host>   # git archive + checksums + stage

# on the KVM host as the invoking user:
deploy/canary/provision.sh                         # boot the disposable guest
bash ~/canary-apt/apt-canary-guest.sh              # verify sums -> install -> fixtures -> matrix -> gates
# review ~/canary-apt/evidence-<ts>/ (logs + REDACTED audit projection), then:
deploy/canary/provision.sh destroy                 # owned guest + storage only
```

## Cleanup boundary

The guest is disposable (cattle). Evidence goes to a fresh per-run
`~/canary-apt/evidence-<ts>-<pid>/`: the matrix/gate logs, dpkg state, and a
**redacted** audit projection (cid, actor, phase, operation, outcome,
`effect_issued`, the Part A durable post-state fields — `observed`, `changed`,
`state_changed`, `observed_failed`, `authorized_via` — so the durable-record
round-trip is visible, and receipt *state* only — never the verifier, any token, or
any bound field; the raw sink never leaves the guest). Then `provision.sh destroy`
removes only the owned domain and its storage; nothing remains on the host but
`~/canary{,-apt}`.
