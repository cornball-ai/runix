# libapt-pkg helper — implementation plan (no code)

Status: implementation plan (pre-code), for review before any privileged C++ is
written. The **second rung** of the apt-mutation verification ladder
(`apt-mutation-boundary-contract.md`, "Verification ladder"): the broker
effect-receipt capability (rung 1) is built and merged (runix-audit-broker #3,
runix #55); this plan covers the `libapt-pkg` helper (rung 2), ahead of the
`pkgops` R API (rung 3).

**This plan does not reopen settled design.** Authorization, approval, the
receipt mechanism, locking, and recovery are fixed by
`apt-mutation-boundary-contract.md` and `broker-effect-receipt-contract.md`,
both of which survived security review. This is an *implementation* plan against
those contracts. Where the spike surfaced a genuine gap, it is called out under
"Open decisions" as a review point — none is a contradiction that forces a
contract amendment (Troy's step 4 bar).

## Deliverable and non-goals

- **Deliverable:** a reviewable plan pinning entrypoints/polkit actions, stdin
  receipt transport, `plan_schema=1` digest generation, the lock/commit
  lifecycle, typed errors, packaging, and the VM test gate.
- **Not now:** no privileged C++, no polkit policy files, no `.deb`, no repo
  created. Implementation begins only after this plan is reviewed.

## Feasibility spike (verified on this host, 2026-08-12, Ubuntu 24.04, apt 2.8.3)

Read-only investigation, no mutation, no privileged code:

1. **libapt-pkg is present; dev headers are not.** Runtime lib
   `libapt-pkg6.0t64` provides `/usr/lib/x86_64-linux-gnu/libapt-pkg.so.6.0`;
   the helper's runtime dependency resolves automatically via
   `${shlibs:Depends}`. `libapt-pkg-dev` and `/usr/include/apt-pkg/` are **not**
   installed — a build dependency to add, and where the exact API symbols get
   confirmed during implementation.
2. **apt 2.8.3 honours `-o DPkg::Lock::Timeout`** (the bounded-wait knob the
   contract's `runix_apt_locked` leans on; present since apt 2.0).
3. **polkit exec-path binding is real and standard.** `pkexec` 124, `pkcheck`,
   and `pkaction` are installed. Existing actions bind an action id to one
   immutable binary via `<annotate key="org.freedesktop.policykit.exec.path">`
   (e.g. `com.feralinteractive.GameMode.*` → `/usr/libexec/cpugovctl`,
   `org.dpkg.pkexec.update-alternatives`). This is exactly the contract's
   "authorization bound to distinct immutable entrypoint paths, verb fixed by
   which binary path, never argv" model.
4. **The non-interactive machine-mode check exists as a tool.** `pkcheck
   -a ACTION -p PID` *without* `--allow-user-interaction` is the
   `CheckAuthorization(AllowUserInteraction = FALSE)` the contract requires for
   `--json` mode; its exit status distinguishes authorized / challenge / denied.
5. **Plan-digest fields are all derivable from libapt-pkg** dep-cache iterators
   (name, arch, install/upgrade/downgrade/remove/purge action, from/to version,
   and the hold/auto/essential/protected flags). Exact accessor symbols are a
   to-confirm against the headers, not a feasibility risk.
6. **Atomic lock→resolve→commit under one context is libapt-pkg's normal flow**
   (`pkgCacheFile` opened with the lock held, `pkgProblemResolver`,
   `pkgPackageManager`/`pkgDPkgPM`), and is precisely what the `apt-get -s` CLI
   bridge cannot give — simulate runs unlocked. RcppAPT (Dirk's, public; not
   checked out locally) and apt-get's own `InstallPackages`/`DoInstall` are the
   API references; the helper links `libapt-pkg` directly and depends on
   neither.
7. **Packaging model exists in-tree:** `runix-audit-broker`'s `debian/`
   (debhelper-compat 13, `hardening=+all`, `Rules-Requires-Root: no`,
   `${shlibs:Depends}`) is the template.

Net: nothing in the spike contradicts either contract. Two refinements the
contracts leave implicit (a polkit rules grant for the autonomous verbs, and
entrypoint grouping by risk class) are surfaced under "Open decisions".

## Repository and layout

**Recommendation: a new repo `runix-apt-helper`** (sibling to
`runix-audit-broker`), not bundled into the audit broker and not into `pkgops`.

- The audit broker is deliberately single-purpose and small; pulling `libapt-pkg`
  (a large C++ dependency and a network-touching acquire path) into the daemon
  that guards audit integrity couples two very different trust surfaces. Keep the
  broker libapt-free.
- `pkgops` is the R API (rung 3); a privileged C++ binary built with debhelper is
  not an R package artifact.
- The new repo reuses the broker's build/CI/hardening/packaging patterns and
  **vendors the shared plan-digest golden corpus** (authored in runix, the same
  source of truth the broker vendors), so the helper's digest bytes are proven
  identical to R's.

Layout (provisional):

```
runix-apt-helper/
  src/            libapt context, policy enforcement, plan digest, redeem client,
                  stdin request parse (Jansson), 7 tiny per-verb main.cc files
  polkit/         7 *.policy actions + one rules.d grant
  tests/          fixtures (vendored corpus), unit + boundary conformance
  debian/         debhelper packaging (broker template)
  deploy/         VM gate wiring (reuses the A1 canary harness)
```

This repo choice is a **review decision** (see Open decisions), not a settled
fact.

## 1. Entrypoints and polkit actions

Per the contract, authorization is bound to **distinct immutable entrypoint
paths**; the verb is fixed by *which binary* was exec'd, never by `argv[0]` or a
`command_line`. One binary per **risk class** (the contract's word), one polkit
action each, all under `/usr/libexec/runix/`:

| binary (`/usr/libexec/runix/`) | polkit action | autonomy | modes within the class |
|---|---|---|---|
| `runix-apt-update` | `ai.cornball.runix.apt.update` | autonomous | — |
| `runix-apt-install` | `ai.cornball.runix.apt.install` | approval (`auth_admin`) | — |
| `runix-apt-remove` | `ai.cornball.runix.apt.remove` | approval (`auth_admin`) | remove \| purge |
| `runix-apt-upgrade` | `ai.cornball.runix.apt.upgrade` | approval (`auth_admin`) | upgrade \| dist_upgrade |
| `runix-apt-configure` | `ai.cornball.runix.apt.configure` | approval (`auth_admin`) | — |
| `runix-apt-hold` | `ai.cornball.runix.apt.hold` | autonomous | — |
| `runix-apt-unhold` | `ai.cornball.runix.apt.unhold` | approval (`auth_admin`) | — |

- **Genuinely distinct binaries, not symlinks or an argv multiplexer.** A shared
  static object set plus 7 tiny `main.cc` files, each hardcoding its verb as a
  **compile-time constant**, compiled to 7 distinct ELF binaries at 7 immutable
  paths. `pkexec` resolves the exec path to a specific action; there is no
  `argv[0]`-selected behaviour and no umbrella action.
- **Risk-class grouping is the contract's model** ("each *risk class* is a
  distinct entrypoint path"). Within `runix-apt-remove`, remove-vs-purge is a
  validated `mode` field on the stdin request — authorization is identical for
  the class, and the exact action is **bound into the plan digest** (the `action`
  field per package), so the committed operation is provably the previewed one;
  purge cannot be swapped in after a remove was approved. Same for
  upgrade/dist_upgrade. (Confirm-at-review: keep this grouping, or split to one
  binary per verb — see Open decisions.)
- **Entrypoint isolation:** code reachable from `runix-apt-update` cannot reach
  install/remove logic (separate translation units per class; the update binary
  does not link the transaction-commit path). A caller holding only the update
  action cannot mutate packages.
- **Machine mode never prompts.** The unprivileged R side runs the
  **non-interactive** authorization check first (`pkcheck -a <action> -p
  <caller-pid,start,uid>`, no `--allow-user-interaction`, or libpolkit-gobject
  equivalent) and launches `pkexec <path>` **only** on an already-authorized
  result. A `challenge` → `runix_approval_required`; a `deny` →
  `runix_unauthorized`; the prompting path is never entered even if a desktop
  polkit agent is present. (This is R-side / `pkgops` work, listed here because it
  gates whether the helper is exec'd at all.)
- **Autonomous verbs need a non-interactive grant.** `apt.update` and `apt.hold`
  are `requires_authorization = TRUE` but `approval_required = FALSE`: an agent
  runs them with no human. polkit authorizes that via a shipped **rules.d** file
  granting *those two actions only* to the Runix service identity without
  authentication; every other action defaults to `auth_admin`, so a human at a
  TTY is prompted and machine mode gets `challenge` → `approval_required`. The
  service-identity definition is an Open decision.

## 2. Receipt transport (stdin, never argv/env)

The contract requires the receipt to move over a **private stdin / FD channel**;
`argv` and the environment are world-readable via `/proc`.

- The R caller spawns `pkexec /usr/libexec/runix/runix-apt-<verb>` with a **pipe
  on stdin** and writes one strict request object, then closes the write end.
  `pkexec` passes stdio through to the target unchanged, so the helper reads it on
  fd 0.
- **Stdin request (strict, non-evaluating), parsed with Jansson** (same strict
  profile as the broker — `JSON_REJECT_DUPLICATES`, complete-input, depth-bounded,
  no trailing content):

  ```jsonc
  { "effect_receipt": "<32-hex token>",   // the receipt, private on stdin
    "plan_schema": 1,
    "packages": ["nginx"],                // validated names; [] where n/a
    "mode": "remove",                     // class-internal variant, enumerated
    "lock_timeout": 30 }                  // seconds → DPkg::Lock::Timeout
  ```

  No pass-through apt flags, no `-o`/`-c`/config paths, no shell, no R. Package
  names are matched to a strict pattern before use; anything else is a
  `schema_invalid`-class refusal before any libapt call.
- **The token is the only secret on stdin; nothing sensitive is on argv/env.**
  `PKEXEC_UID` (the original invoking uid) is read by the helper from its own
  `pkexec`-set environment — it is trusted and *not* caller-supplied, so it is
  never taken from the stdin request.
- The **broker socket path is fixed and compiled in** (broker-owned path per
  `audit-broker-contract.md`), never taken from stdin — a caller-supplied socket
  would be a redemption-target injection.
- A token-non-disclosure test asserts the live token never lands in
  `/proc/<pid>/cmdline` or `/proc/<pid>/environ` for the helper or any child it
  spawns (dpkg/maintainer scripts inherit a sanitized environment with no
  receipt).

## 3. plan_schema = 1 digest generation

`broker-effect-receipt-contract.md` ("Plan digest") pins the byte grammar
exactly; the helper reproduces it from its atomic libapt resolve so its digest
equals R's issue-time digest byte-for-byte.

- **Encoding (schema 1):** SHA-256, lowercase hex, over the canonical UTF-8
  bytes: `plan_schema` then verb, then the per-verb records; fields joined by US
  `0x1f`, records sorted bytewise and joined by RS `0x1e`; the fixed field order
  per verb from the contract. Values are exact (never locale-formatted).
- **Delimiter safety is fail-closed:** a field value containing US/RS or a
  sub-list delimiter (`,` `=`) makes the descriptor uncanonicalisable and is a
  refusal, never escaped or truncated. Valid apt names/versions/arches never
  contain these; the check is a guard, not an expected path.
- **Source of the fields:** the resolved `pkgDepCache` after marking — over the
  **whole transaction** (target + every pulled dependency): name, arch, action
  (install/upgrade/downgrade/remove/purge), from/to version, and the bytewise-
  sorted flag list from `{hold, auto, essential, protected}`. Exact accessor
  symbols confirmed against `libapt-pkg-dev` during implementation.
- **The digest is computed under the held lock**, from the plan that will
  actually commit — so the redeemed hash is the committed plan's hash. If state
  drifted since the unprivileged preview, this digest differs from the bound one
  and the broker refuses redemption (`receipt_mismatch`) → no commit. That is the
  TOCTOU/drift gate.
- **Golden vectors** for every verb (empty and single-record cases included) are
  taken from the shared corpus and asserted in the helper's tests, so R and the C
  helper are proven to agree; the encoding is pinned by test, not prose. When
  the helper's vectors and R's are generated, they come from the **one** corpus
  generator, not two hand-written copies.

## 4. Lock / resolve / redeem / commit lifecycle

One `libapt-pkg` context, one lock held continuously across resolve → enforce →
digest → redeem → commit. No simulate-then-execute, so no window where the lock
is dropped.

1. Parse+validate the stdin request; read `PKEXEC_UID` from the trusted env.
2. Init libapt config/system; set `DPkg::Lock::Timeout = lock_timeout`.
3. **Acquire the dpkg frontend lock** (open `pkgCacheFile` with the lock held).
   Timeout → `runix_apt_locked` (retryable), no effect. Never delete or bypass a
   lock file.
4. **Mark** the requested transaction; run `pkgProblemResolver`.
5. **Enforce policy on the resolved set** (trusted side, the unprivileged preview
   is advisory only): rapt ownership `^r-[a-z]+-[a-z0-9.]+$` over **every** package
   in the plan → `runix_package_not_owned`; a held package's change → refuse with
   the hold surfaced; `Essential`/`required`/protected removal →
   `runix_protected_package`. The pinned predicate is byte-for-byte rapt's, kept
   honest by a cross-repo drift test.
6. **Compute the schema-1 plan digest** from the resolved plan.
7. **Redeem before commit.** Connect to the broker's fixed socket as root; send
   `redeem_receipt { effect_receipt (from stdin), principal_uid (PKEXEC_UID),
   effect { operation = verb, resource, plan_schema, plan_hash } }`. The broker
   verifies uid-0 redeemer, principal == bound actor, verb/resource/plan_hash/
   plan_schema == bound, TTL/boot-id, single-use, and marks redeemed durably
   (fsync) before replying.
8. **Commit only on a valid `redeem_ok`.** Then, still under the same held lock,
   run apt's acquire (fetch archives from the system's configured sources — no
   caller-supplied sources) and `pkgPackageManager::DoInstall`. Tag the
   invocation so the native dpkg transaction (`/var/log/apt/history.log`) is
   reconcilable to the Runix operation.
9. **Any redeem failure, timeout, or disconnect → do not commit** →
   `runix_no_intent`. At-most-once, biased to *not applied*: a spent-but-
   uncommitted receipt leaves a redeemed-no-outcome intent that reconciliation
   resolves as not applied.
10. After commit, check for a broken/half-configured dpkg state; **never report
    ok over a broken database** (`runix_dpkg_broken`, carries the
    `dpkg --configure -a` hint). Release the lock (context teardown).

The helper **writes no audit and evaluates no R.** The unprivileged caller owns
the two-phase audit: it opened the intent (issuing the receipt) before the
helper ran, and closes the outcome via the `binding` after, reading post-state
back through `pkgstate`.

## 5. Typed errors and the helper → R result channel

The helper reports outcome to R by **exit status + a strict stdout result
object**; R maps it to the `runix` condition, does postcondition verification,
and writes the audit outcome.

```jsonc
// helper stdout on completion (strict JSON, one object)
{ "status": "ok" | "no_op" | "<error_code>",
  "observed": { ... },        // optional: broken-state / hold detail for the record
  "diagnostic": "…" }         // tool diagnostic on failure, never secrets
```

Error mapping (all defined in `apt-mutation-boundary-contract.md`, "Typed errors
and retryability"):

| helper condition | code | notes |
|---|---|---|
| lock not taken in window | `runix_apt_locked` | retryable (registry) |
| redeem refused/timeout/disconnect | `runix_no_intent` | fail-closed **before** effect |
| plan touches an `r-*` package | `runix_package_not_owned` | whole resolved plan |
| essential/protected removal | `runix_protected_package` | terminal |
| held package change | (surfaced with hold in `observed`) | not overridden |
| apt/dpkg nonzero | `runix_operation_failed` | carries diagnostic |
| post-commit broken db | `runix_dpkg_broken` | carries repair hint |

Authorization outcomes are decided **before** the helper is exec'd (R-side
`pkcheck` / `pkexec`): denial → `runix_unauthorized`; non-interactive challenge in
`--json` → `runix_approval_required`. The helper itself never prompts and never
sees an interactive path.

All conditions inherit `runix_error`; every attempt — success or any error —
gets a durable two-phase audit record (no silent error paths), written by the
caller.

## 6. Packaging

Modeled on `runix-audit-broker/debian/`:

- **debhelper-compat 13**, `export DEB_BUILD_MAINT_OPTIONS = hardening=+all`,
  `Rules-Requires-Root: no`.
- **Build-Depends:** `debhelper-compat (= 13)`, `libapt-pkg-dev`,
  `libjansson-dev`, `pkg-config`.
- **Depends:** `${shlibs:Depends}` (auto-pulls `libapt-pkg6.0t64`, `libjansson4`),
  `${misc:Depends}`. `pkexec`/polkit at runtime is invoked by the R side; whether
  the runtime polkit dependency sits on this package or on `pkgops` is a small
  packaging decision (the `.policy`/rules files ship here regardless).
- **Installs:** 7 binaries → `/usr/libexec/runix/`; 7 `*.policy` →
  `/usr/share/polkit-1/actions/`; one rules file → `/etc/polkit-1/rules.d/`
  granting the two autonomous actions to the Runix service identity.
- Fits the A0 `.deb` stack (`a0-packaging-plan.md`) as an additional package;
  the `runix-stack` metapackage closure and the `packaging` CI gate extend to it.
- Hardened build under ASan/UBSan for tests, and a sanitizer/fuzz pass over the
  stdin request parser (untrusted input surface), mirroring the broker's CI.

## 7. VM test gate (destructive, disposable guest only)

The final rung: a **minimal** destructive acceptance on a disposable KVM guest
(the A1 canary harness, `deploy/canary/`) — **never the troy-g5 host** (see the
`troy-g5-canary` constraint: destructive testing is VM-only). Fixtures cannot
reproduce the dpkg lock under real contention, maintainer scripts, a genuinely
interrupted transaction, or a partially-configured database. A harmless local
test package and a local repo drive:

- real install / remove / upgrade of the test package (postcondition read back
  via `pkgstate`);
- **held/protected refusal** — an attempted removal of an `Essential` package is
  refused `runix_protected_package`; a held package is not overridden;
- **real lock contention** — hold the dpkg frontend lock in another process;
  assert `runix_apt_locked` within the timeout and clean queueing;
- **interrupted transaction** — SIGKILL the helper mid-commit; assert a
  redeemed-no-outcome intent, reconciled against dpkg ground truth (not assumed
  applied);
- **no-intent bypass** — `pkexec` an entrypoint directly with no / a replayed /
  a plan-mismatched receipt → `runix_no_intent`, no effect;
- **entrypoint isolation** — the update action cannot install/remove;
- **plan drift** — change package state between the unprivileged preview and the
  atomic resolve → `receipt_mismatch`, no commit;
- **non-interactive machine path** — a `--json` gated verb returns a typed
  refusal via the no-interaction check and never prompts, even with a desktop
  polkit agent present.

This mirrors the contract's helper-boundary conformance list (tests 14–21) at the
level fixtures cannot reach.

## Open decisions (for review — none forces a contract amendment)

1. **Runix service identity for the autonomous grant.** The rules.d grant for
   `apt.update`/`apt.hold` needs a subject to grant to (a `runix` system user or
   group the agent runs as / belongs to). The contracts assume "an agent runs
   these autonomously" but do not define the identity. Smallest sound option: a
   `runix` system group, granted the two actions non-interactively; agents run as
   members. This is an *addition* consistent with the contract, not a
   contradiction — but it introduces a concept the contract doesn't name, so it is
   the one item that may warrant a one-line contract note rather than silent
   invention.
2. **Repo placement** — new `runix-apt-helper` (recommended) vs bundling into
   `runix-audit-broker`. Recommendation is separate, to keep the broker
   single-purpose and libapt-free.
3. **Entrypoint grouping** — one binary per risk class with the class-internal
   variant bound by the plan digest (recommended, matches the contract's "risk
   class" wording) vs one binary per verb (9 binaries, maximal isolation, more
   surface).

**Contract-amendment assessment (Troy's step 4):** the spike revealed no concrete
contradiction with either contract. Item 1 is the only candidate for a small
contract note; items 2–3 are implementation choices the contracts leave open.
Recommend proceeding without reopening the contracts, resolving items 1–3 at plan
review.

## Build order (rung 2 internal)

1. Shared object set: stdin parse (Jansson) + strict validation; libapt context
   (init, lock, resolve); policy enforcement; schema-1 digest; broker redeem
   client. Unit-tested against the vendored corpus and an injectable broker/lock.
2. The 7 per-verb `main.cc` entrypoints + polkit `.policy`/rules files.
3. Packaging (`debian/`), hardened + sanitizer/fuzz CI, into the A0 stack + gate.
4. Helper-boundary conformance tests (contract tests 14–21) at fixture level.
5. Hand off to `pkgops` (rung 3): the R API that previews, opens the intent,
   runs the non-interactive auth check, spawns the helper, and closes the
   outcome.
6. The destructive VM gate (rung 4) once `pkgops` can drive the whole chain.

Privileged C++ begins only after this plan is reviewed.
