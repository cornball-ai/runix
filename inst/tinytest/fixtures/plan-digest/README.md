# plan-digest golden vectors

The shared golden corpus for the schema-1 apt plan digest
(`docs/broker-effect-receipt-contract.md`, "Plan digest"). It pins the canonical
byte encoding and its SHA-256 so every implementation produces identical bytes
for the same plan: the `pkgexec` C helper (which vendors `vectors.json` and
tests against it today) and the R preview side (rung 3) when it lands.

`vectors.json` fields per vector:

- `verb` — the operation string (e.g. `apt.install`).
- `records` — the encoder **input**, structured per verb. Deliberately stored
  **unsorted** where ordering matters (multi-record, `flags`, `components`,
  `options`) so a conforming encoder must reorder to reach the canonical form.
- `canonical_hex` — the exact canonical byte string, hex-encoded.
- `sha256` — the SHA-256 of those bytes.

`canonical_hex` and `sha256` were computed **independently of any encoder**
(`printf` of the exact bytes → `xxd`/`sha256sum`), so a conforming encoder is
checked against an outside authority, not against itself. US = `0x1f`, RS =
`0x1e`.

When the R encoder exists it must reproduce every `canonical_hex` and `sha256`
here; `vectors.json` is the single source of truth, vendored (byte-identical)
into `cornball-ai/pkgexec` at `tests/fixtures/plan-digest/`.

`update_inline_signed_by` pins the `signed-by` inline-armored-key normalization
(`docs/broker-effect-receipt-contract.md`, "Plan digest"): an inline PGP key
carries `=` and newlines, so it is replaced with `inline-sha256:<64 lowercase
hex>` over the exact key bytes `libapt-pkg` returns. The record here already holds
that token (the digest operates on the normalized value); its `_note` records the
fixed key K and its SHA-256, so the token is reproducible. `_note` is
documentation only — encoders read `verb`/`records`/`canonical_hex`/`sha256`.
