# The `runix` common core

Decided 2026-08-07. Promotes `runix` from a docs-only umbrella repo into a
small **package** holding the cross-cutting spine that pkgstate, rsystemd,
and rctl have each been reimplementing. Triggered by the spine crossing the
"extract once it repeats" threshold set in
`phase1-introspection-contracts.md` — it has now repeated three times, and
the retryability class string was hand-coupled across repos during the
pkgstate rename (the concrete tell).

## Dependency direction (unchanged, now with a real core)

```text
rctl                      (CLI: JSON encoder, envelope, dispatch)
  |
  v
pkgstate, rsystemd, ...   (subsystem domain packages)
  |
  v
runix                     (common core: conditions, runner, result, retryability)
```

Hard rules:

- **`runix` has zero external (non-base) dependencies.** It is the floor.
- **`runix` never imports a subsystem package** (no pkgstate/rsystemd/rctl).
  The arrow points only downward.
- Subsystem packages `Imports: runix` and delete their local copies.
- rctl `Imports: runix` for the taxonomy/retryability it keys on.

## What `runix` owns

1. **Typed condition constructors + the class taxonomy.** One constructor
   builds the canonical tail `c(<subclass...>, "<pkg>_error", "runix_error",
   "error", "condition")`. Each package's `stop_pkgstate`/`stop_rsystemd`/
   `stop_rctl` becomes a thin wrapper over it (fixed package subclass), so
   `runix_error` and `runix_parse_error` have a single definition instead of
   being restated in every `stop_*`. The structured-data condition path
   (rsystemd's `stop_mutation`, carrying `observed`/`elapsed`/…) moves here
   too as the general form.
2. **Retryability metadata.** A registry + `is_retryable(cond)` predicate
   live in `runix`. Packages declare their retryable classes to the registry
   (e.g. pkgstate registers `pkgstate_cache_race`) rather than rctl
   hardcoding the string. This kills the cross-repo coupling that required a
   hand-edit during the rename — the class and its retryability are declared
   in one place, and rctl asks `runix::is_retryable()`.
3. **The injectable-runner contract.** The normalized `run_system` (LC_ALL=C,
   optional TZ=UTC, stderr capture, missing-tool → typed error) plus the
   `set_runner`/`runner` injection machinery. The two drifted copies
   (rsystemd captures stderr + has the sleeper; pkgstate does not) converge
   on one implementation. Runner *state* stays per-package (each package
   injects its own fake) — `runix` provides the machinery and a state-env
   factory, not one global runner.
4. **`runix_result` structure + helpers.** The generic result object
   (`operation`/`resource`/`changed`/`state_changed`/`preview`/`before`/
   `after`/`planned`/`completion`/`audit`) and its constructor/print. Domain
   results subclass it — rsystemd's `systemd_result` becomes
   `c("systemd_result", "runix_result")` built via the runix constructor.

## What stays out of `runix`

- **The JSON encoder and CLI envelope live in `rctl`** — deterministic
  encoding, yyjsonr backend, the `schema_version`/`ok`/`error` envelope,
  exit-code mapping. These are CLI concerns, not foundational; `runix` must
  not depend on yyjsonr or know about the wire format.
- Anything subsystem-specific (systemd job correlation, apt policy parsing).

## Extraction plan (the focused pass)

Contract-first (this doc) → then implement as a separate change:

1. Scaffold `runix` package in the umbrella repo (or a dedicated one; TBD),
   zero external deps, `OS_type: unix`.
2. Move: condition constructor + taxonomy; retryability registry; runner
   contract; `runix_result`. Fixture tests for each in `runix`.
3. Repoint pkgstate/rsystemd: `Imports: runix`; replace local
   `conditions.R`/`runner.R` with wrappers/re-exports so existing
   `pkg:::set_runner` test hooks keep working (compatibility tests assert
   the hooks still fake correctly).
4. Repoint rctl: `is_retryable` → `runix::is_retryable`; drop the hardcoded
   `RETRYABLE_CLASSES` string in favor of the registry.
5. `saber::blast_radius()` on each moved symbol before moving it; full
   suites green in all four repos + the integration tests.

Blast radius (verified 2026-08-07): condition constructors in 3 packages
(+`stop_mutation`); `run_system`/`set_runner`/`runner` in 2; `runix_error`/
`runix_parse_error` strings across 14 R files (mostly usages, which keep
working); retryability split pkgstate↔rctl; `runix_result` in rsystemd only.
All internal (non-exported) symbols, so no public API breaks — the risk is
test hooks (`pkg:::set_runner`), covered by compatibility tests.

Out of scope here: the rapt→bsrm rename (separate project); any subsystem
behavior change.
