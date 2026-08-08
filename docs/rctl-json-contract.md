# rctl --json: Machine-Interface Contract

Drafted 2026-08-07, before any rctl implementation, per the agent-facing
design section of the Phase 1 contracts. This is the Phase 1 completion
gate: rctl is not "done" as a pretty-printer — `--json` is the stable
interface, and everything below is contract.

## Modes

- **Machine mode** (`--json`): stdout carries **exactly one JSON document**
  per invocation — the envelope — and nothing else. All diagnostics,
  progress, and warnings go to stderr. No human text is ever mixed into
  stdout in machine mode.
- **Human mode** (default, no `--json`): free-form tables and prose for
  people. Explicitly unstable; nothing may parse it. Anything that needs
  stability uses `--json`.

## Envelope

One envelope schema, versioned by an integer that increments only on
breaking envelope changes:

```json
{
  "schema_version": 1,
  "operation": "packages.upgradable",
  "ok": true,
  "result": [ { "package": "alsa-ucm-conf", "...": "..." } ]
}
```

```json
{
  "schema_version": 1,
  "operation": "packages.upgradable",
  "ok": false,
  "error": {
    "class": ["pkgstate_error", "runix_error"],
    "message": "apt-cache policy failed with status 100",
    "retryable": true,
    "resource": "apt-cache"
  }
}
```

Envelope fields (all always present):

- `schema_version`: integer, starts at 1. Covers the envelope shape.
  Per-operation **result** schemas are versioned implicitly by
  (operation, schema_version) and documented alongside the operation.
- `operation`: dotted verb path mirroring the CLI
  (`rctl packages upgradable --json` → `"packages.upgradable"`).
- `ok`: boolean discriminator. Exactly one of `result` / `error` is
  present, matching `ok`.

## Errors

The `error` object is the machine rendering of the typed R conditions the
subsystem packages already raise:

- `class`: the R condition class vector, most specific first
  (e.g. `["pkgstate_unknown_package", "pkgstate_error", "runix_error"]`).
- `message`: human-readable, for logs — agents branch on `class`, never
  on `message`.
- `retryable`: boolean. Each condition class documents its retryability;
  the default is `false`. Cache-race conditions (the "apt cache may have
  changed between queries" family) are `true`; missing tools, parse
  errors against stable formats, and validation errors are `false`.
- `resource`: the affected resource as a string (backend tool, unit name,
  package name, path), or `null` when not attributable.

### Exit codes

| Code | Meaning | Envelope |
|---|---|---|
| 0 | success | `ok: true` |
| 1 | operation failed or refused | `ok: false`, error envelope |
| 2 | usage error (bad arguments/flags) | `ok: false`, error envelope |
| 3 | environment failure (missing subsystem or backend tool) | `ok: false`, error envelope |
| 4 | approval required (well-formed, gated, awaiting out-of-band authorization) | `ok: false`, error envelope, class `runix_approval_required` |

Mapping from condition classes: validation errors → 2; `*_missing_tool`
and absent-subsystem conditions → 3; `runix_approval_required` → 4;
everything else → 1. The error envelope is emitted on stdout even for exit
codes 2, 3, and 4 (machine mode never leaves stdout empty).

**Approval-gated mutations (forward-looking).** A human-gated mutation in
machine mode never blocks on an interactive password (see
`apt-mutation-boundary-contract.md`). It returns exit code 4 with an
error-shaped envelope whose class is `runix_approval_required`, carrying the
operation identity (`correlation_id`) and the computed preview, and issues no
effect. This is neither a failure nor a denial: `runix_unauthorized` (exit 1)
is an actual polkit denial, while `runix_approval_required` (exit 4) is a
well-formed request pending sign-off, resumable by identity. It rides the
existing error-envelope shape, so a consumer that does not recognize the
class degrades gracefully; whether it later earns a dedicated top-level
discriminator is an implementation call to settle when the mutation envelope
lands. `retryable` is `false` (the resolution is approve-and-resume, not
retry-the-call).

## Deterministic encoding

- `NA` (any type) → JSON `null`. Never the string `"NA"`.
- Timestamps (POSIXct, always UTC per the package contracts) →
  RFC 3339 UTC strings with `Z` suffix: `"2026-07-29T19:31:16Z"`.
  Sub-second precision only when the source carries it (journal
  timestamps: microseconds).
- Data frames → arrays of row objects. Column names are the schema;
  object key order is not significant.
- Integers and doubles → JSON numbers, never scientific notation, never
  locale-formatted. Logicals → `true`/`false`.
- **Numeric lexical form** (decided 2026-08-07): backend-specific but
  deterministic. The encoder is yyjsonr (minimum tested version pinned in
  rctl's DESCRIPTION, currently 0.1.22), which writes whole doubles
  type-faithfully with a `.0` marker (`22671360.0`) and integers bare
  (`42`); whole doubles ≥ 1e15 pass through rctl's validated integer
  token and emit bare and exact. Agent consumers MUST compare parsed
  JSON semantics, not raw bytes — the byte-level launcher-parity test is
  an rctl-internal invariant (same binary, both launchers), not a
  cross-version stability promise for numeric spellings.
- Strings are always valid UTF-8. Fields that originate as byte arrays
  (journal messages) are converted at the R API layer; rctl must never
  emit invalid UTF-8 — invalid sequences are replaced with U+FFFD and a
  diagnostic goes to stderr.
- No locale-dependent output of any kind in machine mode: the backends
  already run under LC_ALL=C and TZ=UTC; rctl's own encoding layer is
  locale-independent by construction.

## Capability introspection

`rctl capabilities --json` — **read-only and non-interactive**, always:

```json
{
  "schema_version": 1,
  "operation": "capabilities",
  "ok": true,
  "result": {
    "rctl_version": "0.0.1",
    "operations": ["capabilities", "packages.installed",
      "packages.upgradable", "packages.origins", "packages.candidates",
      "packages.policy", "packages.cache-timestamps", "services.units",
      "services.info", "services.timers", "services.journal",
      "services.state"],
    "subsystems": {
      "pkgstate": {"present": true, "version": "0.0.1.5"},
      "rsystemd": {"present": true, "version": "0.0.1.3"}
    }
  }
}
```

It answers "what can this host do" from installed packages and backend
tool presence. It never prompts, never authenticates, never mutates, and
must succeed (exit 0) even when subsystems are absent — absence is data
(`present: false`).

## Launcher parity

`rctl` is a thin bin script; **all** semantics live in one entrypoint
function (`rctl::main(argv)` returning the exit code). The littler
launcher and the Rscript fallback both exec that same function.

- littler is a dependency of the CLI package only (never of the subsystem
  packages), per the launcher boundary in the Phase 1 contracts.
- Parity is tested, not assumed: the integration suite runs identical
  invocations through both launchers and byte-compares stdout. Startup
  latency may differ; output may not.

## Non-goals of this contract

Streaming/NDJSON output, an agent protocol beyond the CLI (a later layer
adapts these envelopes), mutation verbs (Phase 2 — they will add preview/
dry-run and audit fields to this same envelope), and human-mode
formatting stability.
