# Runix

R-native Unix system administration: coherent R APIs over the native
interfaces Ubuntu already uses (apt, systemd, D-Bus, udev, polkit), plus an
`rctl` CLI on top. No new distribution — stock Ubuntu is the target.

**Status: experimental, pre-0.1 everywhere.** APIs change without
deprecation until the packages reach 0.1.0.

This is the umbrella repository: architecture and documentation, no package
code.

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
| [pkgstate](https://github.com/cornball-ai/pkgstate) | dpkg/apt read-only introspection | experimental |
| [rsystemd](https://github.com/cornball-ai/rsystemd) | systemd read-only introspection | experimental |
| [rapt](https://github.com/cornball-ai/rapt) | apt mutations (Python-free bspm replacement) | shipping |

## License

Documentation and packages © cornball.ai; packages are MIT-licensed
individually.
