# Phase 1 Freeze — 2026-08-07

Every repository carries the annotated tag `phase1` at these commits:

| Repo | Commit | Package version |
|---|---|---|
| runix | d9be982 (`fecf16f` + tag) | — (umbrella, docs only) |
| rdpkg | 03f0952 (`d8a7c30`) | 0.0.1.6 |
| rsystemd | 0251bad (`7da3f90`) | 0.0.1.3 |
| rctl | 6e195b9 (`aa22a01`) | 0.0.1 |

Environment of record: Ubuntu 24.04.4 LTS (noble), systemd 255
(255.4-1ubuntu8.16), dpkg 1.22.6ubuntu6.6, R 4.6.1, littler 0.3.23,
yyjsonr 0.1.22 (bundling yyjson 0.12.0).

State at freeze:

- rdpkg: `dpkg_installed()`, `apt_origins()`, `apt_candidates()`,
  `apt_upgradable()`, `apt_policy()`, `apt_cache_timestamps()` — 148 tests.
- rsystemd: `systemd_units()`, `systemd_journal()`, `systemd_unit_info()`,
  `systemd_timers()`, `systemd_state()` — 100 tests.
- rctl: 12 operations over the versioned JSON envelope (yyjsonr encoder,
  contract in docs/rctl-json-contract.md) — 78 tests.
- Integration: `integration-tests/phase1-milestone.R` 9/9,
  `integration-tests/rctl-launcher-parity.R` 3/3 byte-identical.
- Acceptance: ubuntu-security-status reproduction matches
  `pro security-status --format json` bucket-for-bucket (3,284 installed
  packages at time of test).

Completion-gate status: satisfied per docs/rctl-json-contract.md
(versioned envelopes, typed retryable errors, capability introspection,
deterministic encoding, tested launcher parity).
