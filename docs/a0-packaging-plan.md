# A0 — Signed `.deb` packaging for the Runix stack (plan)

Status: plan (pre-code), approved with amendments (codex, 2026-08-11). Signing is
built before the repository is expanded: the safety boundary is only as sound as
the channel that delivers it, so root-installable artifacts must be
authenticated. The current `Trusted: yes` on the janssonr repo and the A1 canary
is acceptable only for throwaway CI, never for a daily-driver root channel.

## Distribution endgame (why this is a bridge, not the destination)

- **The R packages' canonical home is CRAN.** CRAN + **r2u/rapt** already yields
  *both* `install.packages()` and `apt install` (r2u mirrors CRAN as apt
  binaries) — so when CRAN reopens, the R stack goes there and apt-installability
  comes for free. This signed archive is the bridge while CRAN is closed and the
  stack is pre-1.0.
- **The broker is not a CRAN artifact.** `runix-audit-broker` is a C daemon; its
  endgame is Debian/Ubuntu proper (or it stays in the cornball archive).
  Debian/Ubuntu main is a long, high-latency path — appropriate at 1.0, not now.
- **A0 is groundwork, not throwaway.** The proper debhelper packaging below
  (source packages, `shlibs:Depends`, `.buildinfo`) is exactly what a
  Debian/Ubuntu submission requires; the same source packages feed both. Design
  A0 so it does not fight the CRAN+r2u / Debian endgame.

## Decisions (codex)

1. **One unified signed Cornball archive.** All `r-cornball-*` packages plus the
   broker share one trust domain and one keyring. Per-package repos would add
   configuration and rotation sprawl without meaningful isolation.
2. **Troy owns the archive identity and private-key custody**, with:
   - an **offline primary key**;
   - a **separate archive-signing subkey** (releases are signed by the subkey);
   - an **encrypted offline backup** and a **revocation certificate**;
   - **no primary private key in GitHub**, ever.
   - **Open decision (gates the signing tooling):** are releases **locally
     signed** by Troy (most secure; but manual, and someone must re-sign before
     `Valid-Until` expires), **or** does a **rotatable signing subkey live behind
     a protected CI environment** (enables unattended publication and
     `Valid-Until` refresh, at the cost of the subkey living in CI — revocable
     without touching the primary)? "Human-held" alone conflicts with unattended
     publication and `Valid-Until` refreshes; pick one before the tooling is
     built.
3. **Migrate janssonr into the unified archive.** After these amendments,
   coordinate with the janssonr session; do not maintain two long-term channels.
   The existing `Trusted: yes` janssonr repo folds into the signed archive.
4. **GitHub Pages for v1, without a POSIX atomic-swap promise.** Pages documents
   deployment artifacts/status, not atomic CDN visibility, and has a 1 GB
   published-site limit. Instead of promising an atomic swap, make transient
   publication races **fail closed and recover**: immutable pool paths,
   `Acquire-By-Hash: yes`, and signed metadata. Revisit object storage when the
   suite/arch matrix grows.

## Bootstrap trust (the keyring cannot bootstrap its own repo)

The `cornball-archive-keyring` package lives *inside* the repo it would
authenticate, so it cannot be the root of trust. Documented initial sequence:

1. Download the minimal exported **public key** into `/etc/apt/keyrings/` (an
   operator-installed bootstrap key).
2. **Verify its full fingerprint** against a separately published value.
3. Add the deb822 source with `Signed-By:` that bootstrap key.
4. `apt update`.
5. `apt install cornball-archive-keyring`, which then **owns and updates** the
   keyring at `/usr/share/keyrings/cornball-archive-keyring.gpg`; repoint the
   source's `Signed-By:` there.

Package-managed keys belong in `/usr/share/keyrings`; operator bootstrap keys in
`/etc/apt/keyrings`. Both must be readable by `_apt`. No `apt-key`, no
`Trusted: yes`, no globally trusted key. (apt-secure, sources.list guidance.)

## Key rotation (tested transition, not "dual-sign overlap")

1. Add the **new public key** to the keyring package while releases are still
   signed by the **old** subkey.
2. Let clients receive that keyring update.
3. Switch `Release` signing to the **new** subkey.
4. Retain the old public key for a **bounded overlap**, then remove it.

Do **not** assume `InRelease` supports the intended multi-signature behavior — a
**conformance test** proves it before relying on it. **Compromise recovery is a
separate, out-of-band bootstrap** procedure: a compromised old key cannot
securely authorize its own replacement, so recovery re-runs the fingerprint-
verified bootstrap with a new key announced out of band.

## Debian builds (`build-debs.sh` becomes an orchestrator)

Stop hand-authoring binary `.deb`s. Each package gets real Debian packaging:

- **`dpkg-buildpackage` / debhelper** (`debian/` per package), not hand-rolled
  control files.
- **Native lib deps via `${shlibs:Depends}`** (`dpkg-shlibdeps` derives them from
  the linked objects) — never hardcode `libjansson4`.
- **Publish source packages and `.buildinfo`** alongside the binaries (feeds the
  eventual Debian path and reproducibility).
- **`${DEB_HOST_ARCH}`** — `amd64` is the first matrix value, not metadata baked
  into the design. `runix` and `janssonr` are `Architecture: any` (compiled);
  pure-R packages are `Architecture: all`.
- **Debian version revisions**, e.g. `0.0.1.8-1`.
- **R ≥ 4.6 floor encoded where the compiled artifact requires it.** Depending on
  `r-cornball-janssonr` already brings the floor transitively; don't duplicate a
  blanket `r-base-core (>= 4.6.0)` on every package. It is a binary-ABI fact, not
  a source fact — keep it out of DESCRIPTION `Depends: R (>= ...)`.

## Package graph + optionality (capability-driven)

rctl is capability-driven: `capabilities` reports each subsystem `present:
true/false`, so mandatory subsystem packages would contradict the design.

- **`r-cornball-rctl` Depends:** its direct R Imports (janssonr, runix) + littler.
- **`pkgstate` and `rsystemd` as Recommends** — installed by default, still
  removable.
- **`runix-stack` meta-package** Depends: `r-cornball-rctl`,
  `r-cornball-pkgstate`, `r-cornball-rsystemd`, `runix-audit-broker`.
- **Acceptance/daily-driver command:** `apt install runix-stack` ("install the
  system"), while `rctl` stays independently useful for capability discovery.

> Alignment check (pre-code): rctl's DESCRIPTION currently declares pkgstate /
> rsystemd as **Imports** (hard). For the deb to make them **Recommends**, rctl
> must load them softly (`requireNamespace`, matching the `present:false`
> capability path). Confirm/convert rctl's dependency classes so the R package
> and the deb agree — otherwise a Recommends that R hard-requires is a lie.

## Publication + acceptance

Publication:

- **`Acquire-By-Hash: yes`** and **SHA-256 (or stronger) indexes**.
- **Immutable pool paths** (a `.deb`'s path never changes content).
- A deliberate **`Valid-Until` policy** consistent with the chosen signing
  workflow (local vs CI subkey — decision 2).

Acceptance (clean disposable VM, the reused A1 harness; source added via
`Signed-By`, **no** `Trusted: yes`):

- **Clean install** from the bootstrap key through `apt install runix-stack`.
- **Tampered rejection:** a tampered `InRelease`, a tampered index, and a
  tampered `.deb` are each **rejected**.
- **Interrupted publication:** clients may temporarily fail, but must **never**
  accept inconsistent content (the fail-closed-and-recover property).
- **Upgrade** from one signed repository generation to the next.
- **Key-rotation rehearsal** (the transition above, end to end).
- **Removal** leaves system-owned **audit data intact unless explicitly
  purged**.
- **CLI/systemd/broker:** the A1 gates pass against the **apt-installed** stack —
  closing the loop from "runs from source" to "installs and runs as signed
  `.deb`s."

## Sequencing

1. **Signing foundation** — decide the signing workflow (decision 2); archive
   layout with immutable pool + by-hash; `Release`/`InRelease` generation;
   keyring package + bootstrap doc; rotation doc + `InRelease` multi-sig
   conformance test. (Uses a throwaway test key for CI; the production key is
   Troy's.)
2. **Debian packaging** — `debian/` per package via debhelper; `runix-stack`
   meta; source + `.buildinfo`; the graph + optionality above.
3. **Atomic-enough publication** — staging build, by-hash, signed metadata,
   fail-closed on interruption; migrate janssonr in (coordinated).
4. **Acceptance** — the full matrix above on the disposable VM.

## Open decisions for Troy

1. **Signing workflow** — local-signed releases vs a CI-hosted rotatable signing
   subkey (gates the tooling; see decision 2).
2. **Key generation/custody** — confirm Troy generates the offline primary + the
   signing subkey, the encrypted backup, and the revocation certificate.
3. **janssonr migration timing** — when to fold the janssonr repo into the
   unified archive, and coordinate with that session.
4. **Hosting** — Pages for v1 (accepted) vs object storage now.
