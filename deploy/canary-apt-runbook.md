# Canary apt — pkgexec mutation boundary on a real systemd/polkit host

Status: runbook (executable). This is the **destructive VM gate** for the pkgexec
activation slice (`libapt-pkg-helper-plan.md` §7, contract conformance 14–21) — the
first time the apt-mutation effector (nine root entrypoints + polkit + broker
effect-receipts) runs on a real host. It extends the A1 canary harness
(`deploy/canary/`, same disposable KVM guest, same ownership-marked teardown); the
KVM host's NVIDIA/kernel/boot/networking/SSH/container-runtime are never touched.

## Scope, stated honestly

No R stack is installed. The unprivileged issuer role that `pkgops` will one day
play is stood in for by **`rab-exercise`**, a VM-only, uninstalled driver. So this
proves the **native helper boundary** (parse → policy → digest → redeem gate →
commit → outcome, plus polkit authorization), **not** the future `pkgops`
integration. That is the point of the slice: freeze and prove the boundary before
`pkgops` is built on top of it.

## The two VM-only oracles (never packaged)

- **`pkgexec-plan`** (pkgexec `tools/plan.cc`, root): under the held dpkg lock it
  produces the issue-time `resource` + `plan_hash` for a verb, reusing the
  effector's `pkgx_apt_map_txn` (transactions) and the shared `pkgx_digest_*`
  functions, mirroring the update/hold/configure enumerations. Strict allowlist +
  arity; a policy/ownership/digest failure exits nonzero with no plan; an empty set
  is `status=noop`. It never redeems or commits.
- **`rab-exercise`** (broker `tools/rab-exercise.c`, run as the principal): the
  whole lifecycle in ONE process (the outcome binding is pinned to the opener's
  full process identity). Verifies the broker peer is uid 0; `open_intent(+effect)`;
  hands the receipt to the exact pkexec'd entrypoint over a private stdin pipe;
  strictly validates the result; writes exactly one outcome; wipes both tokens;
  prints only non-secret evidence. `--replay` (update only) re-presents a redeemed
  receipt to prove single-use at the boundary. Any failure after the durable intent
  leaves it open for reconciliation.

Both are compiled+linked in CI as the mutation-path proof; their runtime is VM-only.

## In-guest fixtures

- `aptbot` (uid 1002): the **autonomous** principal, enrolled in
  `runix-apt-autonomous` (may run only `apt.update` and `apt.hold` non-interactively).
- `aptuser` (uid 1003): a **non-member** (the negative-authorization case).
- A local, trusted apt repo (`/srv/canary-repo`) with harmless packages:
  `canary-benign` (1.0/1.1: install/remove/upgrade/hold); `canary-badpost`
  (postinst exits 1, deps satisfied → half-configured → `dpkg_broken`);
  `canary-slow` (postinst sleeps → a catchable SIGKILL window for the interrupted
  transaction); `canary-protected` (`Priority: important` → protected-removal
  refusal); `r-cornball-canary` (matches rapt's `^r-[a-z]+-[a-z0-9.]+$` → the
  ownership `package_not_owned` refusal).
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
| G9 protected removal | `protected_package`, `effect_issued:false`, still installed |
| G-OWN rapt-owned refusal | `package_not_owned`, `effect_issued:false` (ownership before redeem) |
| G10 lock contention | `apt_locked` (fcntl F_SETLK holder excludes `GetLock`) |
| G11a missing receipt | schema refusal (`internal`), `effect_issued:false` |
| G11b invalid receipt | `no_intent`, `detail=receipt_invalid` |
| G12 mismatched receipt | `no_intent`, `detail=receipt_mismatch`, `effect_issued:false` |
| G13 replay | first `ok`; replay `rejected` (`receipt_redeemed`) |
| G14 plan drift | `no_intent`, `detail=receipt_mismatch` |
| G15 entrypoint isolation | a package arg to `update` is **rejected** (`internal`, no effect); nothing installed |
| G-INT interrupted transaction | SIGKILL mid-commit → `outcome=open`; redeemed-no-outcome intent + dpkg ground truth |

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

`build-and-stage.sh` refuses to run unless all three trees are clean, `git
archive`s from exact commits (so what is staged is exactly what is committed and
reviewed), and ships SHA-256 sums the guest verifies before building. The host is a
required argument (no hardcoded default).

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
`effect_issued`, and receipt *state* only — never the verifier or any token; the raw
sink never leaves the guest). Then `provision.sh destroy` removes only the owned domain
and its storage; nothing remains on the host but `~/canary{,-apt}`.
