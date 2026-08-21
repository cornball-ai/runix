# A0 addendum — packaging the apt-mutation arc

Status: **plan / decisions recorded. Implementation held for review.**
Companion to `a0-packaging-plan.md`; read that first.

A0-dev packaged and VM-proved the **read-only** Runix stack
(runix/pkgstate/rsystemd/rctl/broker + the `runix-stack` metapackage). The
**apt-mutation arc** is now complete end to end — `pkgexec` (privileged effectors +
the `runix-apt-preview` planner), `pkgops` (the unprivileged issuer), and `rctl`'s
`apt.*` surface — but none of it is in the A0 packaging graph. This addendum records
the distribution decisions for the arc and scopes the A0-dev integration (step 1).
It does **not** build anything; the packaging work is held for review.

## Decisions (Troy, 2026-08-20)

1. **One versioned trust domain for the production mutation stack.** `pkgexec`, the
   audit broker, and `pkgops` are distributed **together through the signed cornball
   apt repository** — not split across CRAN and a repo. `pkgops` (pure R) **may
   later** also be carried on CRAN, optionally, but the production mutation stack has
   a single signed apt channel.

   This refines `a0-packaging-plan.md`'s "the R packages' canonical home is CRAN"
   lean. That still holds for the **read-only** R packages. The **mutation** stack
   unifies on the apt repo because its two privileged C artifacts — the broker and
   `pkgexec` — can never be CRAN-hosted, so CRAN alone can never deliver the boundary;
   one trust domain beats two for the dangerous path.

2. **`runix-apt` is a separate opt-in metapackage.** Mutation capability is **not**
   added to `runix-stack`. A host gains effectors only by explicitly
   `apt install runix-apt`. Rationale: the effectors are privileged and group-gated
   (`runix-apt-autonomous`); a host that wants the read-only typed surface must not
   acquire a mutation boundary as a side effect of installing `runix-stack`.

3. **A0-release stays deferred** until the broader validation bar is met (see
   "Validation gate" below). This is independent of the distribution choice: the
   signed public archive is not built until the arc has earned the ceremony.

## Extended packaging graph (A0-dev)

Adds to the `a0-packaging-plan.md` table (same debhelper conventions: `r-api-4.0` +
`r-base-core (>= 4.6.0)` on every R binary, `${shlibs:Depends}` for native libs,
`3.0 (native)` source format for A0-dev, `amd64` first).

| deb | arch | Depends | Recommends |
|---|---|---|---|
| `pkgexec` | any | `${shlibs:Depends}` (libapt-pkg, jansson, OpenSSL), `polkit`, `dpkg`, `adduser`, `${misc:Depends}` | |
| `r-cornball-pkgops` | all | `r-base-core (>= 4.6.0)`, `r-api-4.0`, `r-cornball-runix`, `r-cornball-pkgstate`, `r-cornball-janssonr` | `pkgexec` |
| `runix-apt` (meta) | all | `r-cornball-pkgops`, `pkgexec` (exact `=` versions) | |

Notes:

- **`pkgexec` already ships a debhelper `.deb`** (0.0.4, `Architecture: any`, deps
  via `${shlibs:Depends}`, `postinst` creates the `runix-apt-autonomous` group). It
  is *not* a CRAN artifact. Integration is folding it into the A0 orchestrator +
  provenance manifest, not from-scratch packaging.
- **`pkgops` needs the planner at runtime** (`runix-apt-preview`, shipped by
  `pkgexec`), so its `SystemRequirements: pkgexec` becomes a package dependency. A
  `pkgops` without `pkgexec` can preview nothing and commit nothing, so the honest
  install unit is the **`runix-apt` metapackage** that bundles both — hence
  `pkgexec` as a `pkgops` Recommends and an exact-versioned `runix-apt` Depends.
- **`rctl` is unchanged.** It already declares `pkgops` as a runtime-detected
  `Suggests`; with `pkgops` absent, `rctl apt.*` reports the subsystem absent and the
  read-only surface is unaffected. `pkgops` arrives via `runix-apt`, **not** through
  `runix-stack`'s Recommends (which stay pkgstate/rsystemd).
- **The broker** is already packaged and tagged (`v0.0.1` `.deb`) and is shared by
  both stacks (the read-only audit path and the mutation effect-receipt path).
  `runix-apt` pulls it transitively through `runix`.

## A0-dev integration — step 1 scope (HELD for review)

Goal: `pkgexec` + `pkgops` + `runix-apt` build as debhelper `.deb`s and
install/upgrade/remove from **local files on a disposable VM**, with the apt-mutation
gates passing against the **apt-installed** stack (not the source tree). No signing,
no public repository, no CRAN — that is A0-release, deferred.

1. **`pkgexec` into the orchestrator.** It has `debian/` already; wire it into the
   A0 build so it emits the source package + `.buildinfo` + SHA-256 provenance like
   the rest. Verify `dpkg-shlibdeps` resolves libapt-pkg / jansson / OpenSSL / polkit,
   and that `postinst` creates `runix-apt-autonomous` idempotently. `Architecture:
   any` (amd64 first).
2. **`pkgops` debhelper packaging.** New `debian/` — `Architecture: all`, the r-cran
   ABI metadata, Depends on `r-cornball-runix`/`pkgstate`/`janssonr` + `pkgexec`.
   Native source format for A0-dev.
3. **`runix-apt` metapackage.** Meta `.deb` depending on `r-cornball-pkgops` +
   `pkgexec` at exact `=` versions — the opt-in mutation install unit, referenced by
   nothing in `runix-stack`.
4. **VM local-file acceptance (extend the A0-dev `deploy/canary` harness).** On a
   clean disposable guest: `apt install ./runix-stack*.deb ./runix-apt*.deb` from
   local files; upgrade old→new; remove/purge (polkit rules + group cleanup; the
   `/var/log/runix` audit sink survives per the existing operator-owned rule); then
   run the apt-mutation §7 gates + polkit matrix against the **apt-installed** stack,
   closing "runs from source" → "installs and runs as `.deb`s" for the mutation path.
   **Disposable VM only, never the troy-g5 host** ([[troy-g5-canary]] discipline:
   guest only, redacted evidence, independent teardown).
5. **Provenance.** Pin source commits and record artifact SHA-256 in the run
   manifest (existing A0-dev discipline).

CI: a `packaging` gate that builds the arc `.deb`s, installs from local files, and
drives one unprivileged→`pkexec` mutation — mirroring the read-only packaging gate.

**Explicitly out of step 1:** signing, the public/signed repository, CRAN submission,
unattended upgrades, the troy-g5 host, and any real-fleet deployment.

## Validation gate (before A0-release, not step 1)

A0-release waits on "replace the Python admin layer" confidence, which the current
VM proof (happy path + refusals + the §7/polkit gates on the mutation primitive) does
not yet establish. The bar:

- the full fleet pipeline from `roadmap.md` — collect → join → preview → approve →
  **apply** → verify → **resume the failures by operation id** → durable audit — run
  end to end over **real** packages, not just the synthetic canary target;
- **upgrade / rollback** of mutated package state;
- **multi-arch** (the record grammar already keys `package:arch`; prove it on a real
  multi-arch host);
- **failure injection** — interrupted transactions, dpkg-broken pre-state, lock
  contention, broker/persist failures — verifying the outcome-before-signal and
  reconcile-by-cid discipline under fault.

Only once that holds does the signed A0-release archive (keys, `Valid-Until`,
rotation, bootstrap — designed in `a0-packaging-plan.md`) get built.
