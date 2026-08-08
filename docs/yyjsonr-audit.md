# yyjsonr 0.1.22 Targeted Security Review — 2026-08-07

Scope: the JSON **write path** as rctl uses it (`write_json_str`, dataframe
rows, auto_unbox, gated json_verbatim, specials → null). rctl never parses
untrusted JSON; parse/geojson/ndjson paths were confirmed unreachable and
skipped. This is an artifact audit — package source and bundled C — not a
maintainer investigation.

## Provenance

- CRAN source tarball `yyjsonr_0.1.22.tar.gz` byte-identical from two
  mirrors (cloud.r-project.org, cran.r-project.org); sha256
  `ca2c68e0c1589e536bb76aac8235a75d90bde82e32e3367a321a12731fa48b8e`.
- **Bundled yyjson is 0.12.0** (`yyjson.h` version defines; also exposed
  at runtime via `yyjson_version_()`), well past the ≤ 0.8.0
  double-free/RCE issue tracked by Debian for the yyjson source package —
  that CVE does not apply to this bundle.
- Licensing clean: package MIT (Mike Cheng); bundled yyjson carries intact
  upstream MIT headers (© 2020 YaoYuan), credited in `Authors@R` (aut,
  cph), `DESCRIPTION` Copyright, `inst/COPYRIGHTS`, and
  `inst/LICENSE-yyjson.txt`.
- **Bundled-vs-upstream diff**: `src/yyjson.c` and `src/yyjson.h` in the
  CRAN tarball are **byte-identical** to the upstream
  `ibireme/yyjson` 0.12.0 release (`yyjson.c` sha256
  `ac2e9bbb2e2d9149d90878d40506a1d624fa0b33c979a11b61075c54782c6d6a` on
  both sides). Nothing was inserted between upstream and CRAN.

## Supply-chain posture

This audit deliberately stops at artifact provenance, source integrity,
licensing, CVEs, C review, and adversarial tests. Maintainer biography
(nationality, employer) is not part of the assessment, for a security
reason rather than a courtesy one: identity is the weakest link in the
chain to verify — the xz/Jia Tan incident was executed under a fabricated
persona that biographical vetting would have passed — while artifacts can
be verified regardless of who produced them. The controls that actually
bind a hostile- or coerced-maintainer scenario here are:

1. exact-version pin (`>= 0.1.22` audited; upgrades are deliberate);
2. this review was performed on the same bytes we run (mirror-cross-checked
   tarball, sha256 recorded);
3. the bundled C library is diffed against its upstream release, so the
   R-packaging layer cannot silently carry a modified yyjson;
4. no automatic upgrades — every version change re-runs the provenance
   checks and re-checks the bundled yyjson version and diff;
5. escape hatch: yyjson is a two-file MIT library — if trust in the
   packaging chain ever degrades, the audited copy can be vendored into a
   cornball-controlled package without API change;
6. binary channel note: r2u binaries are built by the r2u infrastructure
   from CRAN sources — installing them shifts trust to that build chain.
   Where that is unacceptable, build from the audited source tarball.

## C-glue findings (write path)

Verdict: **safe for rctl's use**. No memory corruption, OOB writes,
double-free, or use-after-free reachable through rctl's calls. Items of
record:

1. `gmtime()` NULL-deref on absurd Date/POSIXct values
   (`R-yyjson-serialize.c:222,255`) — **unreachable from rctl**: the
   encoder converts POSIXct to RFC 3339 strings in R before serialization.
2. `fac[digits]` OOB static read for `digits > 19` — rctl never passes
   `digits`.
3. Error-mid-serialization **leaks** (yyjson doc allocated with libc
   malloc, freed manually, skipped on R longjmp) — never corruption.
   Irrelevant for a short-lived CLI; matters only if the encoder is ever
   embedded in a long-running process that catches errors repeatedly
   (note for any future daemon/harness embedding).
4. `json_verbatim` content is **fully trusted in C** (raw memcpy, no
   UTF-8 or syntax validation). rctl's R-side gate — internal regex-gated
   integer token only, incoming json-class stripped — is load-bearing and
   test-covered (smuggling test).
5. The glue assumes UTF-8 and never calls `translateCharUTF8`;
   declared-latin1 input errors cleanly rather than crashing. Hardened in
   rctl by `enc2utf8()` before validation (rctl#2).
6. Length/dim truncation to `unsigned int` in matrix/array paths — needs
   multi-billion-element inputs; not reachable at CLI scale.

## Adversarial write battery (rctl encoder, all typed or correct)

NaN → null; Inf/-Inf → fail-closed refusal; 2^53 boundary refused; big
whole values exact and bare (positive and negative, including mixed
NA/big vectors); 5 MB strings fine; 5000-deep nesting stopped by R's
C-stack guard as a typed error; multibyte Unicode round-trips; empty
containers and factor columns encode correctly.

## Standing practice

- Pin: rctl Imports `yyjsonr (>= 0.1.22)`; deployment channel is
  `r-cran-yyjsonr` via r2u/rapt.
- Monitor: Debian security tracker for the yyjson source package, yyjsonr
  CRAN releases (re-check the bundled yyjson version on every update),
  and upstream yyjson releases. Re-run this review's checks when the
  bundled version changes.
- Adoption boundary (decided 2026-08-07): yyjsonr is the standard for new
  Runix/rctl JSON paths. No automatic migration elsewhere; jsonlite stays
  where compatibility matters. rsystemd's parser may switch later, only
  after its fixtures pass unchanged against yyjsonr. No shared JSON
  wrapper package.
