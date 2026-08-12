# runix 0.0.1.10

- The audit-broker client adapter now recognizes the effect-receipt
  capability's response shapes (`broker-effect-receipt-contract.md`):
  `.broker_parse_response` classifies a receipt-bearing `open_ok` (with an
  opaque `effect_receipt` token, validated distinct from the outcome binding)
  as `open_ok_effect`, and the root helper's `redeem_receipt` success (a
  correlation id only, no binding or `audit_scope`) as `redeem_ok`. The seven
  new closed-set error codes (`receipt_invalid`, `receipt_expired`,
  `receipt_redeemed`, `receipt_mismatch`, `receipt_unauthorized`,
  `receipt_actor_mismatch`, `effect_without_receipt`) join the accepted set,
  each pinned by a shared-corpus fixture, and a populated `capabilities`
  response gains a golden. Parser only: the sink does not yet request effects.

# runix 0.0.1.9

- The audit-broker client adapter now recognizes the broker's `capabilities`
  discovery response: `.broker_parse_response` classifies it as
  `capabilities_ok`. It is validated as a forward-extensible shape — scalar
  integer `frame_version`/`record_schema_version`, an integer `plan_schemas`
  array, and an `extensions` object whose known `effect_receipt` version is
  checked while unknown extension names are ignored, so future broker
  capabilities never break an older client. Both today's empty response and a
  populated `effect_receipt`/`plan_schemas` response validate. The shared
  broker-frame fixture corpus gains the `capabilities_ok` golden, byte-identical
  to the broker's response builder.

# runix 0.0.1.8

- `actor` is now treated as authority-derived framing metadata (like `host`,
  `pid`, `time`), not subsystem domain content. A new exported `audit_actor()`
  helper is the single source of the normalized `uid:N` identity, and
  `.finish_record` stamps it for local file/memory sinks — so a subsystem hands
  a sink a record that never carries `actor`.
- The audit-broker client adapter now **rejects** a record containing any
  reserved identity/framing key (`actor`, `correlation_id`, `phase`, `host`,
  `pid`, `time`, `binding`, `broker`, `record_type`, `schema_version`) with
  `runix_broker_reserved_field`, locally and before any transport, rather than
  sending it (the broker would reject it `schema_invalid`) or silently
  stripping it. A producer that leaks framing into domain content fails closed
  and named at the seam. Found by the A1 canary: the rsystemd mutation path was
  supplying `actor`, which the broker refused, blocking every unprivileged
  system-scope mutation.
- Contract: `audit-broker-contract.md` and `durable-audit-contract.md` amended
  to state that client-supplied identity/framing fields are forbidden
  (fail-closed), not "ignored and overwritten"; authoritative identity is
  sink-derived.
