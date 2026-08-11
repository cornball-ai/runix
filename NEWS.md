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
