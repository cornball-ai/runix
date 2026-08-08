# Runix

R-native Unix system administration: coherent R APIs over the native
interfaces Ubuntu already uses (apt, systemd, D-Bus, udev, polkit), plus an
`rctl` CLI on top. No new distribution — stock Ubuntu is the target.

**Status: experimental, pre-0.1 everywhere.** APIs change without
deprecation until the packages reach 0.1.0.

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
