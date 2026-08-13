# libapt-pkg helper — implementation plan (no code)

Status: implementation plan (pre-code), **revised after review** (codex,
2026-08-12). The **second rung** of the apt-mutation verification ladder
(`apt-mutation-boundary-contract.md`, "Verification ladder"): the broker
effect-receipt capability (rung 1) is built and merged (runix-audit-broker #3,
runix #55); this plan covers the `libapt-pkg` helper (rung 2), ahead of the
`pkgops` R API (rung 3).

**This plan does not reopen settled design.** Authorization, approval, the
receipt mechanism, locking, and recovery are fixed by
`apt-mutation-boundary-contract.md` and `broker-effect-receipt-contract.md`,
both security-reviewed. Two narrow contract reconciliations this review
*directed* — per-verb entrypoints and the `runix-apt-autonomous` group — land in
the contract alongside this plan; they resolve existing ambiguity, they do not
reopen it.

## Deliverable and non-goals

- **Deliverable:** a reviewable plan pinning entrypoints/polkit actions, stdin
  receipt transport, `plan_schema=1` digest generation, per-mechanism
  lock/commit lifecycles, input limits, environment/FD hygiene, typed errors,
  packaging, and the VM test gate.
- **Not now:** no privileged C++, no polkit files, no `.deb`, no repo created.
  Implementation begins only after this plan is reviewed **and** the
  libapt-pkg-dev API spike (build-order step 0) is done.

## Feasibility spike (verified on this host, 2026-08-12, Ubuntu 24.04, apt 2.8.3)

Read-only, no mutation, no privileged code:

1. **libapt-pkg present; dev headers not.** `libapt-pkg6.0t64` provides
   `/usr/lib/x86_64-linux-gnu/libapt-pkg.so.6.0`; runtime dependency resolves via
   `${shlibs:Depends}`. `libapt-pkg-dev` / `/usr/include/apt-pkg/` are **not**
   installed — a build dependency, and where exact API symbols are confirmed
   before privileged code (build-order step 0).
2. **apt 2.8.3 honours `-o DPkg::Lock::Timeout`** (the `runix_apt_locked`
   bounded wait; present since apt 2.0).
3. **polkit exec-path binding is standard.** `pkexec` 124, `pkcheck`, `pkaction`
   installed; existing actions bind an id to one immutable binary via
   `<annotate key="org.freedesktop.policykit.exec.path">` (GameMode, dpkg's
   update-alternatives). Exactly the contract's "verb fixed by executable path"
   model.
4. **`pkcheck -a ACTION -p PID`** without `--allow-user-interaction` is the
   non-interactive `CheckAuthorization(AllowUserInteraction=FALSE)` for `--json`
   mode.
5. **Plan-digest fields derive from the dep cache** (name, arch, action,
   from/to version, hold/auto/essential/protected flags); exact accessors are a
   step-0 confirm, not a feasibility risk.
6. **Atomic lock→resolve→commit under one context is libapt's normal flow**;
   the `apt-get -s` simulate runs unlocked, which is why the CLI bridge cannot
   provide it. RcppAPT (public, not checked out here) and apt-get's
   `InstallPackages`/`DoInstall` are API references; the helper links
   `libapt-pkg` directly and depends on neither.
7. **Packaging template in-tree:** `runix-audit-broker/debian/` (debhelper-compat
   13, `hardening=+all`, `Rules-Requires-Root: no`, `${shlibs:Depends}`).

## Resolved decisions (codex, 2026-08-12)

1. **Autonomous grant → an opt-in `runix-apt-autonomous` system group, created
   empty, never auto-enrolled.** The shipped rules.d file grants the two
   autonomous actions (`apt.update`, `apt.hold`) only to members of that group,
   non-interactively. Caveat carried into the contract: if an agent shares a
   human UID (e.g. Viento), every process under that UID gains the grant — use a
   dedicated service account where that is unacceptable. Added narrowly to
   `apt-mutation-boundary-contract.md`.
2. **A separate `pkgexec` repo.** libapt and mutation authority stay out
   of the audit broker (which stays single-purpose and libapt-free). The new repo
   reuses the broker's build/CI/hardening/packaging and **vendors the shared
   plan-digest golden corpus** (the one source of truth R also uses).
3. **One immutable binary and polkit action per verb — nine entrypoints.** A
   receipt proves *plan integrity*, not authorization, so a `mode=purge` argument
   through a remove-authorized binary would weaken "verb fixed by executable
   path." No mode multiplexing. This also fixes the contract's "risk-class" vs
   "per-verb" language (reconciled to per-verb in the contract, same PR).

## Repository and layout (`pkgexec`)

```
pkgexec/
  src/            libapt context, policy enforcement, plan digest (OpenSSL EVP),
                  broker redeem client, strict stdin parse (Jansson);
                  9 tiny per-verb main.cc, each a distinct binary
  polkit/         9 *.policy actions + one rules.d grant to runix-apt-autonomous
  tests/          vendored corpus, unit + boundary conformance (contract 14–21)
  debian/         debhelper packaging (broker template)
  deploy/         VM gate wiring (reuses the A1 canary harness)
```

## 1. Entrypoints and polkit actions (nine, per verb)

Nine genuinely distinct binaries under `/usr/libexec/runix/`, one polkit action
each, verb fixed by **which binary was exec'd** — never `argv`, never `argv[0]`,
no umbrella action, no symlink multiplexing:

| binary (`/usr/libexec/runix/`) | polkit action (`ai.cornball.runix.`) | autonomy |
|---|---|---|
| `runix-apt-update` | `apt.update` | autonomous |
| `runix-apt-install` | `apt.install` | approval (`auth_admin`) |
| `runix-apt-remove` | `apt.remove` | approval (`auth_admin`) |
| `runix-apt-purge` | `apt.purge` | approval (`auth_admin`) |
| `runix-apt-upgrade` | `apt.upgrade` | approval (`auth_admin`) |
| `runix-apt-dist-upgrade` | `apt.dist_upgrade` | approval (`auth_admin`) |
| `runix-apt-configure` | `apt.configure` | approval (`auth_admin`) |
| `runix-apt-hold` | `apt.hold` | autonomous |
| `runix-apt-unhold` | `apt.unhold` | approval (`auth_admin`) |

- **Distinct binaries, not symlinks or an argv multiplexer.** A shared static
  object set plus 9 tiny `main.cc` files, each hardcoding its verb as a
  **compile-time constant**, compiled to 9 distinct ELF binaries at 9 immutable
  paths.
- **Entrypoint isolation:** each binary links only its verb's mechanism
  (§4); the `update` binary does not link the transaction-commit path, so a
  caller holding only the update action cannot install or remove.
- **Machine mode never prompts.** The R side (`pkgops`) runs the non-interactive
  check first (`pkcheck -a <action> -p <caller-pid,start,uid>`, no
  `--allow-user-interaction`) and exec's `pkexec <path>` **only** on an
  already-authorized result: `challenge` → `runix_approval_required`, `deny` →
  `runix_unauthorized`, the prompting path never entered even with a desktop
  polkit agent present.
- **Autonomous verbs.** `apt.update`/`apt.hold` are `requires_authorization=TRUE`,
  `approval_required=FALSE`. A shipped rules.d file grants those two actions to
  the `runix-apt-autonomous` group non-interactively; every other action defaults
  to `auth_admin` (human prompt at a TTY, `challenge` in machine mode). The group
  ships **empty** and is never auto-populated.

## 2. Receipt transport (stdin, never argv/env)

The R caller spawns `pkexec /usr/libexec/runix/runix-apt-<verb>` with a **pipe on
stdin**, writes one strict request, and closes the write end. `pkexec` passes
stdio through unchanged; the helper reads fd 0.

```jsonc
// stdin request (strict Jansson: JSON_REJECT_DUPLICATES, complete-input,
// depth-bounded, no trailing content). No mode field — verb is the binary.
{ "effect_receipt": "<32-hex token>",   // the receipt, private on stdin
  "correlation_id": "<broker cid>",     // to mark the native dpkg transaction
  "plan_schema": 1,
  "packages": ["nginx"],                // validated target names; [] where n/a
  "lock_timeout": 30 }                  // seconds → DPkg::Lock::Timeout
```

- No pass-through apt flags, no `-o`/`-c`/config paths, no shell, no R.
- **The token is the only secret, and only on stdin.** `PKEXEC_UID` is read from
  the helper's own trusted `pkexec`-set environment, never from the request. The
  broker socket path is compiled in (broker-owned), never caller-supplied.
- A token-non-disclosure test asserts the live token never appears in
  `/proc/<pid>/cmdline` or `/proc/<pid>/environ` for the helper or any child.

### Strict input limits (enforced before any libapt call)

| limit | value | rationale |
|---|---|---|
| total stdin bytes | ≤ 65536 (64 KiB) | bounded request |
| package count | ≤ 256 | bounded target set |
| package name length | ≤ 256 bytes | dpkg-name bound; validated to a strict pattern |
| `lock_timeout` | integer in `[0, 3600]` | 0 = fail-fast; cap the queue wait |
| JSON nesting depth | ≤ 4 | the request is shallow |
| `effect_receipt` | exactly 32 lowercase hex | token grammar |
| `correlation_id` | broker cid grammar | rejected otherwise |
| `plan_schema` | must equal 1 | the only offered schema |
| **absolute stdin deadline** | 5 s wall-clock to read the full request | anti-slowloris: a caller that opens the pipe and stalls cannot pin a root process open (mirrors the broker's connection deadlines) |

Any breach is a `schema_invalid`-class refusal **before** libapt is touched.

### Sanitized environment and FD policy

- **Environment:** read `PKEXEC_UID` first, then `clearenv()` and set only
  `PATH=/usr/sbin:/usr/bin:/sbin:/bin`, `LC_ALL=C`, `DEBIAN_FRONTEND=noninteractive`.
  Nothing is inherited — `APT_CONFIG`, `DPKG_*`, `LD_*`, `*_proxy`, `PERL5LIB`,
  `BASH_ENV`, `IFS` and the rest are gone. apt reads its own config/proxies from
  `/etc/apt`, not the environment.
- **File descriptors:** parse the request on fd 0, then **replace fd 0 with
  `/dev/null`** before any dpkg or maintainer script runs (no lingering receipt,
  no stdin prompt). dpkg/maintainer-script stdout+stderr go to the helper's
  stderr / apt log — **never** fd 1, which carries only the helper's single
  result object (§5). The broker socket is opened for redemption, then **closed
  after `redeem_ok` and before commit**, and is `CLOEXEC`, so it never leaks to a
  child. All fds ≥ 3 are `CLOEXEC` or explicitly closed before commit.

## 3. plan_schema = 1 digest generation

Reproduces the byte grammar pinned in `broker-effect-receipt-contract.md`
("Plan digest") from the helper's atomic resolve, so its digest equals R's
issue-time digest byte-for-byte.

- **Encoding (schema 1):** SHA-256 (**OpenSSL EVP**, matching the broker's crypto
  choice — not a hand-rolled or vendored SHA-256), lowercase hex, over the
  canonical UTF-8 bytes: `plan_schema`, verb, then per-verb records; fields joined
  by US `0x1f`, records bytewise-sorted and joined by RS `0x1e`.
- **Delimiter safety is fail-closed:** a field containing US/RS/`,`/`=` makes the
  descriptor uncanonicalisable → refusal, never escaped or truncated.
- **Source:** the resolved `pkgDepCache` over the **whole transaction** (target +
  every pulled dependency). Exact accessors confirmed at step 0.
- **Computed under the held lock**, from the plan that will commit, so the
  redeemed hash is the committed plan's hash. Drift since the unprivileged
  preview → different digest → broker refuses (`receipt_mismatch`) → no commit.
  That is the TOCTOU/drift gate.
- **Golden vectors** for every verb (empty and single-record) come from the one
  shared corpus; R and the C helper are proven to agree by test, not prose.

### Canonical `resource`

The receipt binds `resource`, so R (at issue) and the helper (at redeem) must
derive it identically **from the request alone** — R does no atomic resolve, so
`resource` must not depend on resolved dependencies (those live in `plan_hash`):

- **install/remove/purge with explicit targets, and hold/unhold:** `resource` =
  the requested **target** package names, bytewise-sorted ascending, comma-joined,
  under the digest's delimiter-safety rule.
- **upgrade/dist_upgrade (whole-system, v1):** `resource` = `""`. In v1 these are
  whole-system only — the request carries **no** targets and the helper rejects a
  targeted upgrade (`schema_invalid`) rather than silently widening it to the
  whole system; the resolved set is carried by `plan_hash`. Target-scoped
  upgrades are a later addition (they would take the target-names rule above).
- **update:** `resource` = `""` (full refresh) or the sorted source identifiers
  if a subset is requested; the source descriptor is in `plan_hash`.
- **configure:** `resource` = `pending` (the pending-config set); the set is in
  `plan_hash`.

Both sides compute `resource` by the same rule, so issue and redemption cannot
disagree.

## 4. Lock / commit lifecycle — per mechanism

The four verbs' mechanisms differ; a single generic resolve→`DoInstall` does not
describe all of them, and they take different locks. Each holds its lock
continuously across resolve/enforce/digest/redeem/commit — no
simulate-then-execute, no dropped lock — **except B (update)**, whose lists lock
is owned by `ListUpdate`/`pkgAcquire` itself and cannot be held across the
digest→redeem→refresh span; there plan identity is preserved by the retained
`pkgSourceList`, not a held lock (§4B). A and D additionally release the *inner*
dpkg database lock for the `dpkg` run while holding the outer frontend lock
throughout (`UnLockInner`/`LockInner`), which is how dpkg runs without dropping
serialization against other apt frontends.

**A. Package transactions** (`install`, `remove`, `purge`, `upgrade`,
`dist_upgrade`):
1. parse+validate request; read `PKEXEC_UID`; scrub env/FDs.
2. init libapt; set `DPkg::Lock::Timeout`.
3. **acquire the dpkg frontend lock** (open `pkgCacheFile` with the lock);
   timeout → `runix_apt_locked` (retryable), no effect.
4. mark the transaction (purge sets the purge flag; dist_upgrade uses the
   dist-upgrade resolver); run `pkgProblemResolver`.
5. enforce policy on the resolved set (§ Package ownership in the contract):
   rapt `^r-[a-z]+-[a-z0-9.]+$` over **every** package → `runix_package_not_owned`;
   holds → refuse with the hold surfaced; essential/protected removal →
   `runix_protected_package`.
6. compute the schema-1 digest.
7. **redeem before commit** (§ below); on `redeem_ok` only, close the broker
   socket, then `pkgAcquire` from the system's configured sources and
   `pkgPackageManager::DoInstall`, lock still held.
8. post-commit broken/half-configured check → `runix_dpkg_broken`; release lock.

**B. update** (list refresh): **no** dep resolve, **no** `DoInstall`.
`ListUpdate`/`pkgAcquire` refreshes indexes into `/var/lib/apt/lists`, rebuilding
the cache, and **owns the lists lock itself**. So B is the exception to the
continuous-lock rule: the helper does a **non-blocking preflight probe** of the
lists lock (contention → `runix_apt_locked`, retryable), releases it, and
`ListUpdate` re-acquires it — a small preflight race in which a lock grabbed in
the gap degrades to a refresh failure, never a false success. Plan identity is
held not by a lock but by the **retained `pkgSourceList`**: the exact source set
that was digested is the set `ListUpdate` refreshes. The digest is the source-set
descriptor (uri/suite/components/options), not a package plan; redeem still
applies. **Success requires a clean refresh** — `APT::Update::Error-Mode=any`, so
any failed source fails the whole refresh (a partial fetch leaving stale-but-
readable indexes is not success); the ground truth is that result plus a fresh
cache re-opening over the rebuilt indexes. v1 refreshes the whole source list (a
nonempty subset resource is refused). No dpkg invocation, so no broken-state check.

**C. hold / unhold**: writes the dpkg **selection state** (hold ↔ install) with
`dpkg --set-selections`; no `pkgAcquire`, no `DoInstall`. Holds the apt frontend
lock continuously and releases only the **inner** dpkg database lock for the brief
write (`UnLockInner`/`LockInner`), so no other apt frontend interleaves. The digest
is the hold descriptor (package/from_state/to_state); a target whose current
selection is neither `install` nor `hold` is refused. A selection write runs no
maintainer scripts, so no broken-state check — the ground truth is the selection
read back from a fresh cache.

**D. configure** (`dpkg --configure --pending`): runs the pending-config pass;
**no** `pkgAcquire`, **no** resolver. Holds the frontend lock continuously and
releases the **inner** dpkg database lock for the `dpkg` run (as A does inside
`DoInstall`). The digest is the configure descriptor over the pending-config set
`{unpacked, half-configured, triggers-awaited, triggers-pending}`; a
`half-installed` package (an interrupted unpack `--configure` cannot repair) is
**not** a configure target — it is refused as `runix_dpkg_broken` **before** the
receipt is spent. **Ownership still applies**: the pending set is not selectable,
but configuring an `r-*` package runs its maintainer scripts — a mutation of a
rapt-owned package — so a rapt-owned member is `runix_package_not_owned` **before**
the receipt is spent. Post-commit broken-state check applies.

Exact libapt symbols for each lock/resolve/commit path are confirmed at step 0,
before privileged code.

### Redeem (all four)

Connect to the broker's fixed socket as root. **Authenticate the broker before
the token is sent:** after `connect()` and before any byte is written, the
helper reads `SO_PEERCRED` on the connected socket and requires peer uid 0 —
the kernel-verified credentials of the process that bound/listens on the
socket (the broker, or systemd's activation listener). Any other uid → close
the socket with nothing written → `runix_no_intent`. The receipt token is
never written to an unauthenticated peer, so a squatted or misconfigured
socket path cannot harvest it. Then send `redeem_receipt { effect_receipt
(stdin), principal_uid (PKEXEC_UID), effect { operation=verb, resource,
plan_schema, plan_hash } }`. The broker verifies uid-0 redeemer,
principal == bound actor, verb/resource/plan_hash/plan_schema == bound,
TTL/boot-id, single-use, marks redeemed durably (fsync) before replying.
**Commit only on a valid `redeem_ok`.** Any failure/timeout/disconnect →
`runix_no_intent`, no commit (at-most-once, biased to *not applied*). The helper
also **requires the `redeem_ok`'s `correlation_id` to equal the request's
`correlation_id`** before it commits and before it stamps the native-transaction
marker (below); a mismatch is `runix_no_intent`, no commit — so a valid receipt
can never be committed and logged under a substituted operation id.

On that valid `redeem_ok`, the commit runs **in the same libapt context that
was digested**: the same open cache/dep-cache instance whose resolved state
produced the redeemed `plan_hash`, under the same continuously-held lock (§4).
The helper never closes/reopens the cache, drops/reacquires the lock, or
re-resolves between digest, redeem, and commit — a re-resolve after redemption
would sever the digest↔commit binding the receipt exists to prove. If the
context or lock is lost after `redeem_ok`, the receipt is already spent and the
helper fails **without committing**; that is the same redeemed-no-outcome case
as a mid-commit crash, reconciled by the caller against dpkg ground truth (§7).

### Native-transaction marker

The helper stamps the broker `correlation_id` (from stdin) into apt's
transaction record (`/var/log/apt/history.log`) so the native dpkg transaction
is reconcilable to the Runix operation after the fact — via apt's recorded
command-line / comment field for the invocation, plus the start/end window. The
exact apt config key for the marker is confirmed at step 0.

The helper **writes no audit and evaluates no R.** The unprivileged caller owns
the two-phase audit: it opened the intent (issuing the receipt) before the helper
ran, and closes the outcome via the `binding` after, reading post-state through
`pkgstate`.

## 5. Typed errors and the helper → R result channel

Helper reports via **exit status + one strict stdout result object**; R maps it
to the `runix` condition, verifies post-state, and writes the outcome.

```jsonc
{ "status": "ok" | "no_op" | "<error_code>",
  "observed": { ... },   // optional: broken-state / hold detail for the record
  "diagnostic": "…" }    // tool diagnostic on failure, never secrets
```

| helper condition | code | notes |
|---|---|---|
| lock not taken in window | `runix_apt_locked` | retryable |
| redeem refused/timeout/disconnect | `runix_no_intent` | fail-closed **before** effect |
| plan touches an `r-*` package | `runix_package_not_owned` | whole resolved plan |
| essential/protected removal | `runix_protected_package` | terminal |
| held package change | (hold surfaced in `observed`) | not overridden |
| apt/dpkg nonzero | `runix_operation_failed` | carries diagnostic |
| post-commit broken db | `runix_dpkg_broken` | carries repair hint |

Authorization outcomes are decided **before** the helper is exec'd (R-side
`pkcheck`/`pkexec`): denial → `runix_unauthorized`; non-interactive challenge in
`--json` → `runix_approval_required`. The helper never prompts. Every attempt —
success or error — gets a durable two-phase audit record, written by the caller.

## 6. Packaging

Modeled on `runix-audit-broker/debian/`:

- **debhelper-compat 13**, `hardening=+all`, `Rules-Requires-Root: no`.
- **Build-Depends:** `debhelper-compat (= 13)`, `libapt-pkg-dev`,
  `libjansson-dev`, `libssl-dev` (OpenSSL EVP for the digest), `pkg-config`.
- **Depends:** `${shlibs:Depends}` (auto-pulls `libapt-pkg6.0t64`, `libjansson4`,
  `libssl3`), `${misc:Depends}`.
- **Installs:** 9 binaries → `/usr/libexec/runix/`; 9 `*.policy` →
  `/usr/share/polkit-1/actions/`; one rules file → `/etc/polkit-1/rules.d/`
  granting the two autonomous actions to `runix-apt-autonomous`. A maintainer
  script creates the group **empty** (`addgroup --system runix-apt-autonomous`),
  never adding members.
- Fits the A0 `.deb` stack (`a0-packaging-plan.md`) as an added package; the
  `runix-stack` closure and the `packaging` CI gate extend to it.
- Hardened build; ASan/UBSan for tests; a sanitizer/fuzz pass over the stdin
  parser (the untrusted surface), mirroring the broker.

## 7. VM test gate (destructive, disposable guest only)

Minimal destructive acceptance on a disposable KVM guest (the A1 canary harness,
`deploy/canary/`) — **never the troy-g5 host** (destructive testing is VM-only).
A harmless local test package + local repo drive: real install/remove/upgrade
(post-state via `pkgstate`); held/protected refusal; real dpkg-lock contention →
`runix_apt_locked`; an interrupted transaction (SIGKILL mid-commit) →
redeemed-no-outcome intent reconciled against dpkg ground truth; a **failed
maintainer script** (a local package whose `postinst` deliberately exits
non-zero while its dependencies stay satisfied) → the post-effect ground-truth
scan detects the half-configured package (`PkgIterator::State() != NeedsNothing`,
which `BrokenCount` alone would miss) → `runix_dpkg_broken`; no-intent bypass
(direct `pkexec`, no/replayed/mismatched receipt) → `runix_no_intent`; entrypoint
isolation (update cannot install/remove); plan drift → `receipt_mismatch`, no
commit; non-interactive machine path never prompts. Mirrors the contract's
helper-boundary conformance (tests 14–21) at the level fixtures cannot reach.

## Build order (rung 2)

0. **libapt-pkg-dev API spike (gates all privileged code).** Install
   `libapt-pkg-dev` (needs a sudo `apt install` from Troy — Claude Code cannot
   sudo) and write a small **non-privileged, read-only** probe compiled against
   libapt-pkg: init config, open the cache read-only, mark a sample transaction,
   print the resolved plan fields — commits nothing. Confirms the exact
   `pkgCacheFile::Open`/lock/`pkgProblemResolver`/`pkgPackageManager`/`pkgAcquire`
   symbols, the flag accessors, and the history-marker config key. No privileged
   implementation before this passes.
1. Shared object set: strict stdin parse (Jansson) + input-limit/env/FD hygiene;
   libapt context per mechanism; policy enforcement; schema-1 digest (OpenSSL
   EVP); broker redeem client. Unit-tested against the vendored corpus and an
   injectable broker/lock.
2. The 9 per-verb `main.cc` entrypoints + polkit `.policy`/rules files.
3. Packaging (`debian/`), hardened + sanitizer/fuzz CI, into the A0 stack + gate.
4. Helper-boundary conformance tests (contract 14–21) at fixture level.
5. Hand off to `pkgops` (rung 3): preview, open intent, non-interactive auth
   check, spawn helper, close outcome.
6. The destructive VM gate (rung 4) once `pkgops` drives the whole chain.

Privileged C++ begins only after this plan is reviewed and step 0 passes.
