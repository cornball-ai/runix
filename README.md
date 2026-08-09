# Runix

R-native Unix system administration: coherent R APIs over the native
interfaces Ubuntu already uses (apt, systemd, D-Bus, udev, polkit), plus an
`rctl` CLI on top. No new distribution — stock Ubuntu is the target.

**Status: experimental, pre-0.1 everywhere.** APIs change without
deprecation until the packages reach 0.1.0.

## Why Runix

Linux keeps moving its systems-critical tooling out of Python and into
compiled languages: netplan's core now lives in a C library (libnetplan), and
systemd, apt, and dpkg are C/C++. So we asked a question. What if we replaced
the sysadmin Python that Ubuntu ships with R, and made the result more
ergonomic for agents to reason over at the same time?

**Runix turns native Linux administration into typed data and governed
operations, so package, service, and log state can be joined, reasoned about,
and safely acted on across a fleet.**

Honest limit: for a single host with a human at a terminal, native tools
(`apt`, `systemctl`, `journalctl`) are simpler, and Runix has to justify its
complexity. Its value shows up in multi-host, agent-driven workflows, through
stable schemas, typed retryable errors, previews, verified post-state, and
durable audit. R itself doesn't make anything safer; the explicit boundary and
verification discipline do.

The control path stays Python-independent. Native mechanisms stay native; R
does data, policy, orchestration, and a stable interface:

| Surface | Current path | Intended direction | Python on the Runix path |
|---|---|---|---|
| Package reads | `dpkg-query`, `apt-cache` | libapt / RcppAPT-style backend | none |
| systemd and journal | `systemctl`, `journalctl` | sd-bus / sd-journal | none |
| Netplan / NetworkManager | not yet shipped | libnetplan C ABI / NetworkManager D-Bus | none |
| Audit | native C broker | native C broker | none |

Two qualifications:

- This means Runix does not invoke or depend on system Python for those paths.
  It does not mean Python disappears from the host: GNOME Terminal,
  software-properties, release tooling, and cloud-init can still use it.
- A Runix operation can still manage a Python service, and an apt transaction
  can still run arbitrary maintainer scripts. The control path is
  Python-independent; the managed workload need not be.

This repository is both the **`runix` common-core package** (zero-dependency
shared spine: typed conditions, retryability registry, injectable-runner
machinery, neutral result object) and the project umbrella (architecture
docs, integration tests, deployment). The package builds from the repo root;
`docs/`, `integration-tests/`, and `deploy/` are `.Rbuildignore`d.

- [docs/roadmap.md](docs/roadmap.md) — mission, built-so-far, prioritized gaps
- [PLAN.md](PLAN.md) — the full design: goals, phases, privilege model,
  language boundaries
- [docs/ubuntu-python-admin-inventory.md](docs/ubuntu-python-admin-inventory.md)
  — Phase 0: which first-party Ubuntu administrative capabilities depend on
  Python, surveyed on a live 24.04 system
- [docs/phase1-introspection-contracts.md](docs/phase1-introspection-contracts.md)
  — Phase 1: read-only API contracts, dependency direction, testing strategy

## Packages

| Package | Scope | Status |
|---|---|---|
| runix (this repo) | zero-dep common core: conditions, retryability, runner, result | experimental |
| [pkgstate](https://github.com/cornball-ai/pkgstate) | dpkg/apt read-only introspection | experimental |
| [rsystemd](https://github.com/cornball-ai/rsystemd) | systemd introspection + managed mutation | experimental |
| [rctl](https://github.com/cornball-ai/rctl) | machine-drivable CLI over the subsystems | experimental |
| [rapt](https://github.com/cornball-ai/rapt) | r2u binary R-package install backend (bspm alternative) | shipping |

## License

Documentation and packages © cornball.ai; packages are MIT-licensed
individually.
