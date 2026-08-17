# runix 0.0.1.12

- The exported slice-2 effect-session surface (pkgops slice 2 complete), over
  the native C core:
  - `effect_capability(socket_path, plan_schema)` negotiates the broker's
    effect-receipt extension and plan schema (the real compatibility gate on
    top of `broker_available()`'s peer auth). Fail-closed to
    `runix_capability_unavailable` on an absent extension, an unaccepted plan
    schema, or an unreachable/untrusted broker; nothing is minted. The broker
    peer is pinned to root.
  - The three-call session API: `effect_session_open()` returns an opaque,
    PID-bound handle object carrying only the external pointer and the
    non-secret correlation id (never a receipt, binding, or path), and raises
    the typed broker taxonomy on failure; `effect_session_commit()` returns the
    helper's raw result verbatim (the issuer, not runix, maps the 12-status
    vocabulary) and refuses fail-closed on a platform without the atomic
    fd-close primitive; `effect_session_write_outcome()` validates the record
    and returns the raw status. `print` methods show state/cid, never a secret.
  - `runix_effect_conditions`: documents the effect-session condition taxonomy
    (which subclasses runix raises versus the issuer) and the retryability rule.

# runix 0.0.1.11

- Native effect-session groundwork (pkgops slice 2). The broker C client
  (`src/unix_socket.c`) now links `libjansson` (anticonf `configure`; a new
  `SystemRequirements`) for strict, in-C extraction on the coming
  effect-receipt path, so the single-use receipt and outcome binding will be
  parsed and wiped in C and never become R objects.
- The socket exchange is refactored into a shared byte-level transport
  (`rab_transport`) operating on plain `malloc` buffers; `C_rab_broker_call`
  keeps its existing behavior (copying the response into a `RAWSXP` for
  non-secret payloads) while the effect session will parse-and-wipe the same
  buffer before any R object exists. One transport, two consumers, no
  duplicated socket code.
- `C_rab_broker_call` now REFUSES any request whose body carries a top-level
  `effect` member (new transport status `runix_effect_via_generic_path`): a
  receipt-minting `open_intent` is serviceable only through the effect session,
  making "the receipt never reaches R" a property of the API rather than a
  caller convention.
- The native effect session itself (`src/effect_session.c`): a PID-bound
  `EXTPTRSXP` handle over an `open_intent(+effect)` -> `write_outcome` state
  machine. The single-use effect receipt and outcome binding are extracted from
  the broker response with linked Jansson, in C, into wipeable heap
  (`explicit_bzero` on consumption and in the finalizer) and NEVER become R
  objects; R sees only the handle, the correlation id, and a status. The handle
  refuses reuse, a `fork` (owner-PID mismatch), and a restore-from-disk (a
  serialized external pointer loses its address). The finalizer only wipes, so a
  dropped handle leaves the intent open (fail-closed). `.Call` entry points
  `effect_session_open`/`write_outcome`/`state`; the verb is a runix-owned
  closed enum mapped in C to the immutable pkexec entrypoint (no path crosses
  from R).
- `effect_session_commit`: `posix_spawn` (no shell) of `pkexec` + this verb's
  immutable entrypoint. The commit request (with the receipt) is delivered on
  the child's stdin and `explicit_bzero`'d the instant it is sent; the strict
  result (`{status, effect_issued, correlation_id, detail}`) is read from the
  child's stdout under a wall-clock deadline (SIGKILL on overrun).
  `effect_issued` is the helper's authoritative boolean, `FALSE` only when the
  effect provably did not run (spawn failed, or pkexec denied before exec), and
  `NA` only when it is genuinely unknown (the child ran but produced no valid
  result). The fake-entrypoint test seam is compile-time only
  (`-DRUNIX_TESTING`), ABSENT from the production build: no runtime environment
  variable can redirect the production pkexec target.
- Commit-path hardening (review of the C3 core):
  - The broker peer uid the transport authenticates is now PINNED to root (0)
    in the shipped build; it is no longer an R argument. Only a
    `-DRUNIX_TESTING` build reads `RUNIX_TEST_PEER_UID`, so nothing R passes can
    lower the authentication bar on the production path.
  - The pkexec entrypoint's bounded request grammar (package count <= 256,
    Debian-name pattern, per-verb arity, duplicate refusal, 64 KiB body cap) is
    enforced in C BEFORE the single-use receipt is spent -- a list the helper
    would reject never costs a receipt.
  - The receipt is delivered to the child only with `SIGPIPE` ignored and a
    usable deadline; if that guard cannot be established the write is refused and
    the effect is left UNKNOWN, never risking a signal-kill of the R process.
    Every `posix_spawn_file_actions_*` return is checked (a bad dup2/close aborts
    before spawn), and all inherited descriptors >= 3 are closed in the child
    (`addclosefrom_np`, glibc 2.34+).
  - A result whose `detail` exceeds 128 bytes, or whose exit code contradicts its
    status (exit 0 iff `ok`/`no_op`), is rejected as malformed and classified
    effect-UNKNOWN rather than trusted or truncated.
  - A commit that overruns its deadline `SIGKILL`s pkexec but classifies the
    outcome as effect-UNKNOWN: the privileged apt work runs in a separate polkit
    scope that killing pkexec need not stop, so a late-completing mutation must
    never be read as "did not run".
- Second review round (three follow-up blockers):
  - A commit result is trusted only when the receipt was actually DELIVERED: an
    undelivered receipt whose child nonetheless returns a valid, correlation-id
    matching result (a guessed or replayed id) is classified effect-UNKNOWN, not
    trusted.
  - The fd-hygiene invariant is held only by the ATOMIC in-child close
    primitive (`addclosefrom_np`), never a racy parent-side sweep: on a platform
    without it the commit path is refused fail-closed rather than spawned with
    an unbounded fd set. A new `effect_session_commit_supported()` reports
    whether commit is available so a caller (and the coming effect-capability
    gate) can discover the refusal without minting a receipt.
  - Every native string input is rejected if it carries an embedded NUL
    (byte-length != C-string length) before validation or serialization, so a
    hand-built `CHARSXP` cannot be truncated silently. (Ordinary R construction
    already refuses embedded NULs, so this guards a non-standard C caller.)

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
