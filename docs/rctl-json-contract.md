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

### Result-schema evolution

The envelope `schema_version` covers the envelope shape only; per-operation
`result` schemas are versioned implicitly by (operation, schema_version) and
documented alongside the operation. Within a fixed envelope `schema_version`,
result fields evolve under these rules:

- **Additive fields do not bump the version.** A new result field on an
  operation is a compatible change; `schema_version` stays `1`.
- **Old consumers ignore unknown fields.** A consumer written against an
  earlier field set MUST tolerate result keys it does not recognize.
- **New consumers fail closed on absent required fields.** A consumer that
  requires a field MUST refuse (error) rather than guess when that field is
  missing — absence is not a default value.
- **Breaking changes bump the version.** Removing, renaming, retyping, or
  changing the *meaning* of an existing result field is breaking and bumps
  the envelope `schema_version`.

**A field can stop being additive.** If a newly added field becomes necessary
to interpret an existing operation *safely* — such that a consumer ignoring it
would act on a misleading result — adding it is no longer a compatible change:
it requires capability negotiation or a `schema_version` bump. Symmetrically, a
consumer MAY fail closed on an optional capability it cannot obtain, but a
producer MUST NOT silently change the meaning of an existing result under an
unchanged version.

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
computed preview and the operation's `correlation_id` for audit reference, and
issues no effect. This is neither a failure nor a denial: `runix_unauthorized`
(exit 1) is an actual polkit denial, while `runix_approval_required` (exit 4) is
a well-formed request pending sign-off. **In v1 it is terminal:** the durable
record is a complete intent + `approval_required` outcome (one `correlation_id`,
`effect_issued = FALSE`), and a human applies it by running a **fresh
interactive command** that recomputes and re-authorizes from current state — not
by resuming an id. Unattended resume-by-id is deferred (it needs a durable
approval store and a broker schema extension; see
`apt-mutation-boundary-contract.md`), so the `correlation_id` here is audit
evidence, never a bearer token. It rides the existing error-envelope shape, so a
consumer that does not recognize the class degrades gracefully. `retryable` is
`false` (the resolution is approve-and-re-run, not retry-the-call).

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
- **Numeric lexical form** (decided 2026-08-07; encoder changed to
  janssonr 2026-08-10): backend-specific but deterministic. The encoder is
  janssonr (the R Jansson binding, minimum tested version pinned in rctl's
  DESCRIPTION, currently 0.0.1.1), which writes a whole double losslessly
  as a bare integer literal (`22671360`, no `.0`), a fractional double as
  itself (`0.5`), and integers bare (`42`); a whole double ≥ 1e15 emits bare
  and exact, and one that cannot round-trip (≥ 2^53 or non-integral) is
  refused rather than corrupted. JSON has a single numeric type, so
  **numeric semantics — not lexical spelling — are contractual**, and
  `schema_version` stays `1` across this spelling change (the earlier yyjsonr
  encoder wrote whole doubles as `22671360.0`). Agent consumers MUST compare
  parsed JSON semantics, not raw bytes — the byte-level launcher-parity test
  is an rctl-internal invariant (same binary, both launchers), not a
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
    },
    "audit": {
      "system_durable_audit": false,
      "audit_scope": "caller"
    }
  }
}
```

It answers "what can this host do" from installed packages and backend
tool presence. It never prompts, never authenticates, never mutates, and
must succeed (exit 0) even when subsystems are absent — absence is data
(`present: false`).

**Audit capability.** The `audit` block advertises the durability an
unprivileged caller would actually get (`durable-audit-contract.md`):
`system_durable_audit` is `true` only when a system-durable path exists (the
caller is root, or the audit broker is present), and `audit_scope` is the
scope a mutation's record would be written under (`"system"` | `"caller"`).
A fleet policy reads this to **refuse** system-scope mutations on hosts where
`system_durable_audit` is `false`, so autonomous fleet-wide system mutation
stays off until the broker exists. This is a capability, not a hidden
downgrade: the weaker guarantee is visible before a mutation is attempted.

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
