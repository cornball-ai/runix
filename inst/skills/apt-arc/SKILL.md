---
name: apt-arc
description: >
  Develop and operate the runix apt-mutation arc: the audited, polkit-authorized
  path from an R call to a committed apt change. Use when working on pkgops,
  pkgexec, pkgstate, the runix effect-session / audit broker, or the rctl apt.*
  CLI — changing a verb, the effect-receipt lifecycle, the polkit authorization
  branch, the durable audit record, or the disposable-VM gates. Covers the arc's
  package roles, the load-bearing safety invariants, and which canary runbook to
  walk. All packages are public.
---

# The runix apt-mutation arc

The arc turns an R call into an **audited, OS-authorized apt change**. Every mutation
crosses a boundary that is authorized by polkit, effected by a privileged helper,
witnessed by a single-use broker receipt, and recorded as a durable audit record —
and refuses closed at every step where it can't prove it's safe.

The whole arc is landed on master and functionally complete (`rctl apt install nginx
--json` drives preview → commit → audit end to end). The frontier is the **A0
release**, not more features (see below).

## The flow

```
apt_<verb>_preview()  →  advisory plan + plan_hash   (unprivileged, no lock, no intent, mints nothing)
        │
apt_<verb>(preview)   →  capability → polkit authorize → open effect-intent
        │                   → privileged helper commits under the dpkg lock
        │                   → redeem single-use broker receipt (cid-matched)
        │                   → verify post-state against ground truth
        │                   → write durable outcome record  (before any signal)
```

## The packages (all public)

| package | role |
|---|---|
| **runix** | core. Native **wipeable C effect-session** (receipt custody), `effect_capability`, the broker transport, and the `runix_effect_conditions` taxonomy. |
| **pkgexec** | the privileged effectors — nine per-verb `pkexec`/polkit entrypoints + the unprivileged `runix-apt-preview` planner. **The security boundary.** Ships as a `.deb`. |
| **pkgops** | the unprivileged R issuer. Nine `apt_<verb>_preview()` + nine `apt_<verb>()` commit entrypoints. **Mutation-capable.** |
| **pkgstate** | verification ground truth: `dpkg_installed()` (state words), `dpkg_selections()` (want words / hold). |
| **runix-audit-broker** | advertises, mints, redeems, and records effect-receipts. It does **not** authorize. |
| **rctl** | the `apt.*` CLI — 18 operations (a read-only `-preview` + a mutating commit per verb), always machine-mode. |

## Load-bearing invariants

These are the places the general audit/broker model does **not** transfer cleanly to
apt. Getting one wrong is a correctness or safety defect, not a style nit.

- **Authorization is polkit, not the broker.** Interactive → `pkexec` prompts at
  commit; machine → `pkcheck --action-id ai.cornball.runix.apt.<verb>`. The broker only
  advertises / mints / redeems / records.
- **`requires_authorization` ≠ `approval_required`.** Distinct axes — `apt.update` may
  need no human approval yet still need OS authorization. Never collapse them.
- **Receipt custody is a native wipeable C session in runix — never a `CHARSXP`.** R
  can't wipe a `CHARSXP`; the receipt must live in runix's C heap and be
  `explicit_bzero`'d on every exit path.
- **`effect_issued` is the helper's authoritative boolean and is tri-state**
  (TRUE / FALSE / NA). Never infer it from the status — `dpkg_broken` can be either.
  NA only for effect-unknown / malformed / process death.
- **Outcome is closed before any failure condition is signaled.** A known failure
  closes then raises; effect-unknown / process death / persist-fail leaves the intent
  open and never fabricates `effect_issued:false`.
- **Commit only after a `redeem_ok` whose `correlation_id` matches**, holding the same
  libapt lock/context from resolve through redeem to commit — never drop and reacquire
  between the digested plan and `DoInstall`.
- **The verb is fixed by exec path**, not argv or a mode flag, and the
  verb → `/usr/libexec/pkgexec/runix-apt-<verb>` map is a **hard C constant** in runix
  with no runtime seam. A fake commit path behind a test seam can't gain privilege.
- **`plan_hash` is the integrity authority.** Locked re-resolution under the dpkg lock
  is authoritative; a drifted preview → `no_intent` at redeem (a safe availability
  refusal, not an integrity gap). pkgops never re-derives the hash at R.
- **The broker `RECORD_SCHEMA` is a 16-field closed allow-list** (version 1) and
  hard-rejects any non-allow-list field or reserved key as `schema_invalid`. The R
  adapter only checks the reserved keys locally, so a stray field passes hermetic tests
  and fails at the real broker — **this is why the disposable-VM gate is mandatory** and
  a hermetic pass is never sufficient for a record-grammar change.

## Which runbook to walk

Both are executable runbooks in `runix/deploy/`, both run in a **disposable KVM guest**
(host systemd, polkit, and `SO_PEERCRED` peer identity don't reproduce in a container),
and **neither ever touches the development host** — a freshly provisioned guest only.

- **`deploy/canary-a1-runbook.md`** — the Runix-only slice: the whole mutation boundary
  on a real systemd/polkit host with no Viento in the loop.
- **`deploy/canary-apt-runbook.md`** — the destructive apt gate: the pkgexec effectors
  and the pkgops issuer, driving the §7 functional gates through the **real**
  `pkgops::apt_<verb>()` path plus the polkit matrix. This is the gate that catches
  effector bugs only a live `dpkg` run surfaces.

Run destructive tests only against a harmless local test package/repository, and leave
`rapt` untouched.

## Canonical contracts

The durable design lives in `runix/docs/` — read the contract before changing the
behavior it pins, not this skill:

- `apt-mutation-boundary-contract.md` — the boundary itself
- `broker-effect-receipt-contract.md` — the receipt lifecycle + golden vectors
- `audit-broker-contract.md`, `durable-audit-contract.md` — the broker + durable record
- `libapt-pkg-helper-plan.md` — the pkgexec helper (its §7 is the conformance gate)
- `pkgops-plan.md`, `pkgops-implementation-plan.md` — the issuer
- `rctl-json-contract.md` — the CLI envelope
- `roadmap.md` — arc sequencing and status

## Frontier: the A0 release

The arc is done as code; what remains is shipping it. A0-dev packaging of the
read-only runtime stack is done: apt-installable as local `.deb`s, gated by a
required `packaging` CI check, proven on disposable guests
(`docs/a0-packaging-plan.md`, `docs/a0-apt-arc-addendum.md`). A0-release,
the signed public archive, is deferred.

1. **pkgexec is still an untagged, unpublished `.deb`, and pkgops is not
   packaged.** The privileged effectors + polkit rules are the security
   boundary and exist only as merged source. Scoping their packaging, then
   tagging, building, and publishing to the cornball apt repo (janssonr's
   pattern) is the deploy gate.
2. **R-package distribution is an OPEN question — CRAN vs a proper apt/deb repo — and
   it is the maintainer's to decide** after more local testing. **Do NOT start CRAN
   prep**; CRAN submission is always the maintainer's action.

Never run either runbook against the development host.
