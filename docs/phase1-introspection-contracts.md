# Phase 1: Read-Only Introspection — API Contracts

Drafted 2026-08-07. Defines the stable structured R APIs for the first two Runix
packages **before** any backend is chosen, per the Phase 1 kickoff constraints:

1. Phase 1 is strictly read-only. No package mutations, no service mutations.
2. Separate packages per concern — no monolithic Runix package.
3. `ubuntu-security-status` is the **acceptance consumer**, not the first
   implementation target: the APIs are done when its output can be reproduced
   from them, but we do not start by porting it.
4. API contracts (this document) come first; each backend
   (libapt-pkg, sd-bus, sd-journal, or a temporary CLI bridge under PLAN.md's
   bridge discipline) is chosen per-function afterward.
5. Fixture tests plus live Ubuntu smoke tests (`tinytest::at_home()`).
6. Nothing mutates, and `ubuntu-security-status` is not replaced, until these
   read-only contracts stabilize.

## Package boundaries

Two packages. Names provisional (rsystemd is already in PLAN.md; the apt-read
name needs Troy's sign-off):

- **rdpkg** — installed-package state (dpkg) and archive/candidate state (apt):
  what is installed, what is available, where it comes from.
- **rsystemd** — units, timers, journal, system state. Read-only subset of
  PLAN.md's rsystemd; the mutation API (`systemd_start()` etc.) waits for
  Phase 2.

Shared conventions live in this doc, not in a shared package (no premature
`runix` core; extract commonality only when it repeats).

## Conventions (both packages)

- Every listing function returns a plain `data.frame` (no tibbles, no classes
  beyond `data.frame`), `stringsAsFactors = FALSE`, stable column order as
  documented, zero-row data frame with the same columns when nothing matches.
- Scalars/records return named lists with documented names.
- Fail-closed: a missing backend tool or unparseable output is an error
  (typed condition), never a guess. An absent *subsystem* (e.g. no systemd)
  is an error, not an empty result — emptiness must mean "queried fine,
  nothing there".
- Typed conditions: errors inherit from `runix_error`; per-package subclasses
  `rdpkg_error`, `rsystemd_error`; parse failures add `runix_parse_error`.
- All time columns are `POSIXct` in UTC. All size columns are numeric bytes.
- Backend functions are injectable: each package has an
  internal runner the tests replace with fakes; exported functions never call
  `system2()` directly.
- Functional style (recorded 2026-08-07): **functional core → imperative
  system boundary.** R shapes Runix toward a functional, data-oriented
  public API without pretending the operating system is functional.
  Concretely:
  - plain data frames/lists for observations (packages, units, devices,
    interfaces);
  - explicit verbs for effects (`systemd_restart()`, `apt_install()`,
    `netplan_apply()` — later phases), each returning a structured result
    object;
  - pure parsers and validators separated from runners and native calls;
  - immutable-style configuration objects, typed conditions for failures
    (parse, authorization, missing tools);
  - S3 for lightweight semantics; R6/environments reserved for genuinely
    stateful resources (D-Bus connections, subscriptions, event monitors);
  - no Python-style class hierarchies or everything-is-an-object APIs —
    when replacing a Python tool, re-express its classes as function
    pipelines over these data frames (ubuntu-security-status is the first
    test of this).
- No masking of base names; no non-base dependencies in Imports beyond what
  the chosen backend forces (target: zero).

## rdpkg contract

```r
dpkg_installed()
# data.frame: package, version, architecture, status
#   status: "installed" | "config-files" | ... (dpkg status word, verbatim)

apt_candidates(packages)
# packages: character vector of package names, length >= 1, like
#   apt_origins (packages = NULL reserved for the native libapt backend).
#   (Amended 2026-08-07; was packages = NULL with an architecture column.)
# data.frame: package, installed, candidate
#   package echoes the queried spelling (name, or name:arch for non-native
#   architectures); the bridge cannot attribute an architecture column
#   honestly, so it returns with the native backend. Version columns are
#   NA where apt reports (none). Unknown names yield zero rows.

apt_upgradable()
# data.frame: package, installed, candidate, origin, site, suite,
#             component, security, phased_percent
#   Semantics: one row per installed package whose candidate version
#   differs from the installed version — "candidate-available".
#   Actionability (phasing cohort membership, dpkg holds, dependency
#   holds) is deliberately NOT decided here: phased_percent (integer, NA
#   when unannotated) and the origin columns give callers the data, and
#   an "actually actionable" plan query belongs to Phase 2 alongside
#   mutations. origin/site/suite/component describe the candidate
#   version's best source; security: logical, candidate served from a
#   security pocket. package echoes the queried name/name:arch spelling;
#   architecture column deferred to the native backend like
#   apt_candidates.
#   phased_percent semantics (stable): the archive's
#   Phased-Update-Percentage annotation on the candidate version
#   ("(phased N%)" in policy output), integer 0-100, NA when unannotated,
#   passed through from apt verbatim. It describes archive-side rollout
#   state, NOT this machine's cohort membership — cohort membership and
#   actionability are Phase 2 planning semantics, distinct by design from
#   candidate-available.
#   Bridge mechanism: a single pass over the same bridge parsers used by
#   dpkg_installed/apt_candidates/apt_origins — no new parser. (Amended
#   2026-08-07: dropped architecture, added phased_percent, pinned
#   candidate-available semantics.)

apt_origins(packages)
# packages: character vector of package names, length >= 1. The
#   all-known-packages form (packages = NULL) is reserved for the native
#   libapt backend — the CLI bridge cannot enumerate the archive without
#   abusing the command line. (Amended 2026-08-07; was packages = NULL.)
# data.frame: package, version, priority, origin, site, suite, component,
#             installed
#   One row per (package, available version, source) — the raw material for
#   any origin classification (main/universe/ESM/PPA/third-party).
#   origin is apt's Origin label (o=..., e.g. "Ubuntu"). The dpkg status
#   pseudo-source has origin "", site "", suite "now", component "".
#   installed marks the version table's *** row; priority is the source's
#   pin priority (can be negative, e.g. -1 for versions absent from any
#   archive). trusted is dropped from the bridge contract — apt-cache
#   policy does not expose it; it returns with the native backend.
#   Unknown package names yield zero rows, not an error (the bridge only
#   reports them on stderr); callers needing existence checks join against
#   dpkg_installed() or apt_candidates().
#   Bridge mechanism: one global `apt-cache policy` call provides the
#   release-field lookup (URI + dist + arch -> origin/suite/component),
#   joined against chunked per-package calls (1000 names per invocation).

apt_policy(package)
# Single-package diagnostic view. Differentiation from the bulk views
# (clarified 2026-08-07): apt_origins() gives per-source rows without pin
# state; apt_candidates() gives resolution results; apt_policy() explains
# WHY resolution went that way for one package — the package pin when
# present, and each version's EFFECTIVE priority (the number pins alter,
# distinct from per-source pin priorities; can be negative, e.g. -1 for
# pinned-out versions), alongside the sources.
# list: package, installed, candidate,
#       pin (version string; NA when no "Package pin:" is reported),
#       versions (data.frame: version, version_priority (effective,
#       integer), priority (source), origin, site, suite, component,
#       installed)
# Unknown package: an error (class rdpkg_unknown_package) — a diagnostic
# view of nothing is a question answered "no such package", unlike the
# bulk views' zero-row semantics.

apt_cache_timestamps()
# Read-only status query. (Renamed from apt_cache_updated 2026-08-07 so the
# name cannot read as a verb: nothing in Phase 1 refreshes the apt cache -
# cache refresh is a mutation and belongs to Phase 2.)
# list: lists_updated (POSIXct — newest /var/lib/apt/lists stamp; NA when
#       the directory holds no index stamps, i.e. never updated),
#       status_changed (POSIXct — dpkg status mtime)
# Paths are arguments with system defaults so tests inject fixtures;
# a missing path is an error, never NA.
```

Origin classification (which origins count as Ubuntu main vs universe vs
ESM vs third-party) is **deliberately not** an rdpkg API: it is Ubuntu policy,
not package state. It belongs to the acceptance consumer, driven by fixtures
(see below). rdpkg's job ends at faithful origin rows.

## rsystemd contract

```r
systemd_units(pattern = NULL)
# data.frame: unit, load_state, active_state, sub_state, description
#   pattern: optional glob, server-side filtering where the backend allows

systemd_unit_info(unit)
# named list of typed properties (documented subset, not the full 200+):
#   unit, description, load_state, active_state, sub_state, unit_file_state,
#   fragment_path, active_enter_time (POSIXct), main_pid (integer),
#   memory_current (numeric bytes, NA if unset), restarts (integer)
# Bridge notes (2026-08-07): systemctl show key=value with the runner
# forcing LC_ALL=C and TZ=UTC, so timestamps parse deterministically as
# "%a %Y-%m-%d %H:%M:%S UTC" ("n/a" or empty means NA). MainPID=0 means
# NA; MemoryCurrent "[not set]" means NA. A not-found unit RETURNS its
# record (load_state "not-found") — absence of a unit is data here, not
# an error.

systemd_timers()
# data.frame: timer, next_elapse (POSIXct), last_trigger (POSIXct),
#             activates, active_state
# Aggregation (2026-08-07): list-timers --output=json carries usec-epoch
# numbers (null means NA) but no unit state; active_state is joined from
# systemd_units(). Two backend calls, both JSON.

systemd_journal(unit = NULL, priority = NULL, since = NULL,
                until = NULL, n = 1000L)
# data.frame: time (POSIXct), priority (integer 0-7), unit, pid (integer),
#             message
#   n caps rows returned (newest last); priority filters at-or-above severity

systemd_state()
# list: state ("running" | "degraded" | ...), failed_units (character vector)
# Aggregation (2026-08-07): `systemctl is-system-running` exits non-zero
# whenever the word is not "running" — for this one command the exit code
# is data, not an error; the word is taken from stdout regardless.
# failed_units aggregates systemd_units() rows with active_state "failed".
```

## Backend candidates (decision deferred, per constraint 4)

Documented so the choice is made per-function with evidence, not by default:

| API area | Bridge candidate | Native candidate |
|---|---|---|
| dpkg_installed | `dpkg-query -W -f` (stable, documented format) | libapt-pkg |
| apt_candidates / origins / policy | `apt-cache policy` (semi-stable; apt CLI warns its own interface is unstable) | **libapt-pkg** — RcppAPT is prior art; likely the first native binding Phase 1 justifies |
| systemd_units / timers | `systemctl list-units --output=json` (machine format, systemd ≥ 249; this box: 255) | sd-bus `ListUnits` |
| systemd_unit_info | `systemctl show -p` (key=value, stable) | sd-bus `GetAll` |
| systemd_journal | `journalctl -o json` (stable NDJSON, documented) | sd-journal |
| systemd_state | `systemctl is-system-running` + `--failed` | sd-bus properties |

The systemd bridges emit machine-readable JSON — materially safer than text
scraping and a legitimate medium-term resting point. The apt side is where the
bridge is weakest (apt's CLI explicitly disclaims stability), which is the
argument for libapt-pkg arriving first there. Every bridge follows PLAN.md's
bridge discipline (LC_ALL=C, fail-closed, verified postconditions n/a for
read-only, injectable runners, native-shaped return types).

## Acceptance: ubuntu-security-status as consumer

Done means: a short R script using only rdpkg exported functions reproduces,
on this machine, the package counts ubuntu-security-status reports (packages by
origin class, ESM-eligible counts), validated against the live tool's output.

**Status: met 2026-08-07.** rdpkg's acceptance test mirrors uaclient's
classifier (`get_origin_for_installed_package`: installed version's sources
in order; candidate fallback when the installed version is status-only;
first Ubuntu source's component wins) from `dpkg_installed()` +
`apt_origins()` + `apt_candidates()` with the explicit installed-package
vector, and matches `pro security-status --format json` bucket-for-bucket
(main+restricted, universe+multiverse, third-party, unknown, total). The
all-known-packages form stays reserved for the native libapt backend.

The origin-classification table is extracted **mechanically** from the tool's
source with bonsaisitter + treesitter.python — verified working today:

```r
lang <- treesitter.python::language()
src  <- paste(readLines("/usr/bin/ubuntu-security-status"), collapse = "\n")
root <- bonsaisitter::tree_root_node(bonsaisitter::text_parse(src, lang))
q    <- bonsaisitter::query(lang,
         "(assignment left: (identifier) @name right: (tuple) @tuple)")
ca   <- bonsaisitter::query_captures(q, root)
# 20 suite_* tuples: suite_main, suite_esm_main, suite_esm_apps, ...
```

That extraction becomes a generated fixture
(`inst/tinytest/fixtures/uss-origin-tuples.json` plus the generator script in
`tools/`), so when Ubuntu changes the tool, regenerating the fixture shows the
drift as a diff instead of a silent test failure.

bonsaisitter caveats that matter here (from today's verification): query
predicates (`#eq?`/`#match?`) are unimplemented — filter captures in R;
patterns anchored at `module` can silently match nothing — query unanchored
and filter by parent; `treesitter.c` is not installed locally and CRAN's
hard-Imports the Posit runtime (flagged in bonsaisitter's todo) — C-header
analysis for the native backends will want that resolved, with treesitter.cpp
(ABI 14) as the workable stand-in meanwhile.

## Testing strategy

- **Fixture tests** (always run, including R CMD check): recorded real outputs
  of each bridge command (`dpkg-query`, `apt-cache policy`,
  `systemctl --output=json`, `journalctl -o json`) live in
  `inst/tinytest/fixtures/`; parsers run against them offline via the
  injectable runner. Malformed-input fixtures prove fail-closed behavior.
- **Live smoke tests** (`at_home()` only): each exported function runs against
  this machine and asserts invariants (columns, types, non-empty where
  guaranteed — e.g. `systemd_units()` must contain `-.mount`), not exact values.
- **Acceptance test** (`at_home()` only): the ubuntu-security-status
  reproduction script, compared to the live tool via
  `pro security-status --format json`. This comparison is a local
  acceptance gate only — never a normal package-check or CI dependency;
  R CMD check and CI run fixture-only.

## Cross-package acceptance and the completion gate (recorded 2026-08-07)

Cross-package acceptance tests live in the umbrella repo's
`integration-tests/` directory (subsystem packages must not depend on each
other), mirroring PLAN.md's first concrete milestone: upgradable packages,
failed units, and error-priority journal entries retrieved in one script
from both packages.

**Phase 1 completion gate**: Phase 1 is not complete until `rctl --json`
ships with **versioned output schemas** and **machine-readable error
envelopes** (schema version, ok/error discriminator, error class,
retryability, affected resource) — a thin pretty-printing wrapper does not
satisfy the agent-facing design section above.

## Out of scope for Phase 1

Mutations of any kind; rctl (waits until the R APIs settle); rdbus (the JSON
bridges defer it); replacement of any Python tool; netplan work (Phase 4
candidate, needs Phase 2/3 first); packaging/distribution (Phase 6).

## Decisions (Troy, 2026-08-07)

1. **Package name: rdpkg.** Read-only, scope stated explicitly: dpkg
   status/database plus apt metadata queries (candidates, origins,
   upgradeability). Mutations stay in rapt; no `rapt.query`; rapt's
   dependency surface does not grow.
2. **Repositories: top-level `~/rdpkg` and `~/rsystemd`**, matching the
   independent-package architecture — no later repository split. Local-only
   for now (no GitHub); work happens on feature branches over the skeleton
   baseline commit.

## Architecture: dependency direction (recorded 2026-08-07)

Thin and acyclic. Arrows are the only permitted dependency directions:

```text
rctl (CLI frontend)
  |
  v
subsystem packages: rdpkg, rsystemd, rudev, rnetwork, rpolkit, ...
  |
  v
runix (small common layer)
```

- **runix** provides shared conventions, common condition classes/types,
  aggregation, and cross-subsystem helpers. It does **not** reimplement
  subsystems and does not necessarily import any of them.
- Subsystem packages never import each other, and nothing imports upward.
- **rctl** is the CLI frontend over the subsystem APIs, nothing more.
- Phase 1 note: the injectable runner and condition helpers are deliberately
  duplicated in rdpkg and rsystemd for now; they migrate down into runix once
  the pattern survives review, not before.

**rnetwork and Netplan**: rnetwork is the eventual home for both
NetworkManager and Netplan integration, but Netplan is an **optional
backend** — they are related layers, and ordinary NetworkManager users must
not acquire a mandatory libnetplan dependency (runtime-detected /
Suggests-level, never Imports/SystemRequirements for the NM path).

**rpolkit** exposes authorization/policy integration when something needs
explicit `CheckAuthorization`; service-level authorization (the target
daemon's own polkit checks) remains the primary mechanism where available.

## Agent-facing design (recorded 2026-08-07)

Runix must be easy for AI agents and orchestration harnesses (the public
corteza runtime among them) to drive through stable machine interfaces,
without private coupling. These requirements are orthogonal to the
subsystem packages and bind the whole stack:

- deterministic structured results with versioned schemas;
- `rctl` emits JSON in data mode with **no human text mixed into data
  output** — prose goes to stderr or human mode only;
- structured, typed errors carrying retryability and the affected
  resources;
- explicit capability/introspection commands (what can this host do,
  which subsystems are present, which verbs are available);
- bounded timeouts, cancellation, and injectable runners throughout;
- no implicit prompts and no interactive authentication in machine mode;
- read-only operations are the default posture;
- mutations require explicit verbs with previews/dry-runs, idempotence,
  and audit records;
- arbitrary R evaluation is **never** a privilege mechanism.

Division of labor: rdpkg, rsystemd, and later subsystem packages expose
deterministic R APIs (this contract); `rctl --json` and a future agent
protocol adapt those APIs for automation. Orchestrators — corteza-based
agents and other harnesses — drive the public interfaces only.

**rctl launcher (recorded 2026-08-07)**: littler (`r`) is the CLI launcher —
fast startup, conventional Unix command behavior — and nothing more:
`rctl → littler launcher → Runix APIs → subsystem packages`. littler never
appears in rdpkg, rsystemd, or the common layer; it is an explicit
dependency of the CLI package alone (the Ubuntu `.deb` may Depend on it),
with an `Rscript` fallback for portability. It optimizes delivery and
startup; it does not shape the subsystem APIs.

**Tree-sitter isolation**: source-analysis tooling (bonsaisitter +
treesitter.* — including CRAN's treesitter.c for C sources, whose Imports
situation is a known portability concern) lives only behind the
fixture-generator boundary: `tools/` scripts that emit committed fixture
files. It never appears in any subsystem package's Imports or Suggests, and
the injectable runner + fixture harness work without Tree-sitter installed —
fixtures are committed artifacts, not build-time products.

## Repository layout

- `~/runix` — umbrella: PLAN.md, this contract, the Phase 0 inventory.
  No package code.
- `~/rdpkg` — apt/dpkg read APIs. Scaffolded 2026-08-07 (0.0.1, MIT,
  OS_type: unix, tinytest wired, installs and tests clean).
- `~/rsystemd` — systemd read APIs. Same scaffold, same date.
- Neither package depends on the other; both are governed by this contract.
  rapt is unchanged and owns all apt mutations.
