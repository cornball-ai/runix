# A0 — `.deb` packaging for the Runix stack (plan)

Status: plan. **Split into two stages** (2026-08-11): don't move from "prove the
packaging" into "operate a public production archive" before Runix deserves that
ceremony.

- **A0-dev (now)** — build the `.deb`s, get architecture and dependencies right,
  and test install / upgrade / remove from **local files on disposable VMs**
  (`apt install ./r-cornball-*.deb`). No archive key, no public repository.
- **A0-release (deferred)** — the unified signed repository: signing keys,
  rotation, `Valid-Until`, atomic publication, public bootstrap. Documented
  below but **not built now**.

**Signing becomes mandatory before** we call the channel production-ready,
recommend it publicly, or use it for unattended fleet deployment — **not
before**. Until then the existing `Trusted: yes` channels are **experimental**.

## Distribution endgame (why any of this is a bridge)

- **The R packages' canonical home is CRAN.** CRAN + **r2u/rapt** yields both
  `install.packages()` and `apt install` (r2u mirrors CRAN as apt binaries), so
  once CRAN reopens the R stack goes there and apt-installability comes for free.
- **The broker is not a CRAN artifact** (`runix-audit-broker` is a C daemon); its
  endgame is Debian/Ubuntu proper, at 1.0.
- **A0-dev is groundwork, not throwaway.** Proper debhelper packaging (source
  packages, `shlibs:Depends`, `.buildinfo`) is exactly what a Debian submission
  and A0-release both need — the same source packages feed all of it.

---

# A0-dev (now)

Goal: correct, installable `.deb`s, verified from local files on throwaway VMs.

## Build: `build-debs.sh` becomes a debhelper orchestrator

Stop hand-authoring binary `.deb`s. Each package gets real Debian packaging:

- **`dpkg-buildpackage` / debhelper** (`debian/` per package), not hand-rolled
  control files.
- **Native lib deps via `${shlibs:Depends}`** (`dpkg-shlibdeps` derives them from
  the linked objects) — never hardcode `libjansson4`.
- **Emit source packages and `.buildinfo`** alongside the binaries (feeds Debian
  + A0-release; reproducibility).
- **`${DEB_HOST_ARCH}`** — `amd64` is the first build target, not metadata baked
  into the design. `runix` and `janssonr` are `Architecture: any` (compiled);
  pure-R packages are `Architecture: all`.
- **Native source format** (`3.0 (native)`, version == R version) for A0-dev —
  matches the broker's packaging and needs no orig-tarball juggling. The
  non-native `-1` revisions + orig tarballs arrive with the Debian submission.
- **Every R binary directly declares the R interpreter + ABI**:
  `r-base-core (>= 4.6.0), r-api-4.0` on each package (the r-cran convention /
  dh-r-equivalent metadata) — not left to `janssonr`/`runix` pulling R
  transitively. The `>= 4.6.0` floor stays out of DESCRIPTION `Depends: R (>= ...)`
  (a binary-ABI fact, not a source fact); `r-api-4.0` guards against R ABI breaks
  a bare version floor would miss.

## Package graph + optionality (capability-driven)

rctl reports each subsystem `present: true/false`, so mandatory subsystem
packages would contradict the design.

| deb | arch | Depends | Recommends |
|---|---|---|---|
| `r-cornball-janssonr` | any | `r-base-core (>= 4.6.0)`, `r-api-4.0`, `${shlibs:Depends}` | |
| `r-cornball-runix` | any | `r-base-core (>= 4.6.0)`, `r-api-4.0`, `${shlibs:Depends}`, `r-cornball-janssonr` | |
| `r-cornball-pkgstate` | all | `r-base-core (>= 4.6.0)`, `r-api-4.0`, `r-cornball-runix` | |
| `r-cornball-rsystemd` | all | `r-base-core (>= 4.6.0)`, `r-api-4.0`, `r-cornball-janssonr`, `r-cornball-runix` | |
| `r-cornball-rctl` | all | `r-base-core (>= 4.6.0)`, `r-api-4.0`, `r-cornball-janssonr`, `r-cornball-runix` | `r-cornball-pkgstate`, `r-cornball-rsystemd` |
| `runix-audit-broker` | any | `${shlibs:Depends}` | |
| `runix-stack` (meta) | all | `r-cornball-rctl`, `r-cornball-pkgstate`, `r-cornball-rsystemd`, `runix-audit-broker` | |

- **`runix-stack`** is the daily-driver handle: "install the system" =
  `apt install ./runix-stack*.deb` (pulls the rest); `rctl` stays independently
  useful for capability discovery, with pkgstate/rsystemd as removable
  Recommends.

> Alignment check (resolved in code): rctl's DESCRIPTION already declares
> pkgstate / rsystemd as **Suggests** (soft, runtime-detected), so **Recommends**
> is honest — no rctl change needed. (janssonr for A0-dev: use the existing
> `r-cornball-janssonr` apt binary; its own debian/ packaging is the janssonr
> session's.)

> `littler` dropped from rctl's Depends (was in the pre-code graph). Two reasons,
> one evidential: (1) rctl's DESCRIPTION lists littler as a **Suggests**, so a
> hard Depends would be a dishonest declaration; (2) the A1 canary showed the
> distribution's littler is ABI-pinned to R 4.3 and cannot co-install with the
> CRAN R (>= 4.6) the stack requires — a hard Depends would make rctl
> **uninstallable** in the exact environment A0-dev targets. `/usr/bin/rctl` is
> therefore the Rscript launcher (`rctl-rscript`), which needs no littler. A
> CRAN-R-compatible littler returns as an optional Recommends once one is
> packaged (r2u/rapt).

## Testing (local files, disposable VMs only)

Reuse the A1 harness (`deploy/canary/`). On a clean disposable guest, with the
built `.deb`s copied in (no repository):

- **install** — `apt install ./r-cornball-*.deb ./runix-stack*.deb` resolves the
  graph from local files (janssonr from its apt binary as the one external dep).
- **upgrade** — install an older build, then a newer, no manual steps.
- **remove / purge** — the R packages ship no conffiles, so `apt remove` leaves
  no `rc` residue; the broker leaves only debhelper's socket-unit lifecycle
  state, cleared on `purge`. The durable audit sink (`/var/log/runix`) is
  runtime-created by the broker daemon, **not package-tracked**, so it survives
  both `remove` and `purge` — audit evidence is operator-owned state that apt
  never deletes as a side effect (consistent with "audit records are evidence";
  deleting it is a deliberate operator action). Verified on the A0-dev canary.
- **acceptance** — the A1 gates (`rctl capabilities`, an unprivileged
  `services.restart` through the broker, durable intent+outcome) pass against the
  **apt-installed** stack — closing the loop from "runs from source" to
  "installs and runs as `.deb`s."

## Current-experimentation constraints (mandatory)

- **Installs confined to disposable VMs.**
- **Pin source commits and record artifact SHA-256 hashes** in the run manifest.
- **Do not deploy an unsigned / `Trusted: yes` repository across the fleet.**
- **Do not enable unattended upgrades** from it.
- **Label existing unsigned repositories experimental** (the janssonr apt repo
  and the A1 canary source).

---

# A0-release (deferred — do NOT build now)

The unified signed public archive. Gated behind Runix being good enough to
deserve it (production-ready claim / public recommendation / unattended fleet).
Kept here so the design is ready when that day comes.

- **One unified signed Cornball archive** — all `r-cornball-*` + broker, one
  keyring, one trust domain.
- **Key custody (Troy):** offline **primary**; separate archive-signing
  **subkey**; encrypted offline backup + revocation certificate; **no primary in
  GitHub**. **Signing workflow decided: local signing by Troy** (releases signed
  on Troy's machine with the offline subkey; no signing key in CI; `Valid-Until`
  refreshed by manual re-sign, so sized for that cadence).
- **Bootstrap trust** (the keyring can't bootstrap its own repo): download the
  minimal public key to `/etc/apt/keyrings/`, **verify the full fingerprint**
  against a separately published value, add the deb822 source with `Signed-By:`,
  `apt update`, then `apt install cornball-archive-keyring` which owns
  `/usr/share/keyrings/...`. No `apt-key`, no `Trusted: yes`. Both key dirs
  readable by `_apt`.
- **Rotation** (tested transition, not "dual-sign overlap"): ship the new public
  key in the keyring package while still signing with the old subkey → let
  clients update → switch `Release` signing to the new subkey → bounded overlap
  → remove the old. An **`InRelease` multi-sig conformance test** proves the
  behavior before we rely on it. **Compromise recovery is a separate out-of-band
  bootstrap** (a compromised key can't authorize its own replacement).
- **Migrate janssonr in** — fold the `Trusted: yes` janssonr repo into the signed
  archive; don't keep two long-term channels. Coordinate with that session.
- **Publication** — Pages for v1 (no POSIX atomic-swap promise; 1 GB limit):
  **immutable pool paths**, **`Acquire-By-Hash: yes`**, SHA-256+ indexes, signed
  metadata, so transient races **fail closed and recover**. A **`Valid-Until`**
  window sized for manual local re-signing. Object storage when the matrix grows.
- **Acceptance (adds to A0-dev):** clean install from the fingerprint-verified
  bootstrap key through `runix-stack`; tampered `InRelease` / index / `.deb` each
  rejected; interrupted publication never yields inconsistent content; upgrade
  across signed-repo generations; key-rotation rehearsal.

---

## Sequencing

1. **A0-dev** (now) — debhelper packaging, arch/deps, `runix-stack`, local-file
   install/upgrade/remove + A1-gate acceptance on disposable VMs.
2. **Slice B** — Viento → rctl, when Viento's boundary is ready.
3. **A0-release** (later) — the signed public archive, when Runix deserves the
   ceremony.

## Open decisions for Troy (A0-release, not now)

- **Key generation/custody** — Troy generates the offline primary + subkey,
  backup, revocation cert (plan supplies the procedure; keys never enter CI or
  this agent's hands).
- **janssonr migration timing** and **hosting** (Pages vs object storage).
