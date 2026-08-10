## Shared broker-response fixtures: the exact-schema accept/reject corpus for the
## R response validator (runix:::.broker_parse_response). These body bytes are
## what the broker's Jansson response builder emits (the accepts are its golden
## shapes) and what the yyjsonr-based validator must accept/reject in lockstep.
##
## The dup-key cases -- one top-level, one NESTED -- are the yyjsonr behavioural
## tripwire: yyjsonr has no duplicate-key read flag but PRESERVES duplicates as
## repeated names, which is what lets .broker_has_bad_keys reject them
## recursively. If a future yyjsonr silently collapsed duplicates, these two
## would stop being rejected via the dup path and the test flips.
broker_response_fixtures <- list(
    ## --- valid shapes (accept) ---
    list(name = "open_ok", accept = TRUE, kind = "open_ok",
         body = '{"audit_scope":"system","binding":"b","correlation_id":"c","ok":true,"persisted":true}'),
    list(name = "outcome_ok", accept = TRUE, kind = "outcome_ok",
         body = '{"ok":true,"persisted":true}'),
    list(name = "emit_ok", accept = TRUE, kind = "emit_ok",
         body = '{"audit_scope":"system","correlation_id":"c","ok":true,"persisted":true}'),
    list(name = "error", accept = TRUE, kind = "error",
         body = '{"error":"schema_invalid","message":"nope","ok":false}'),
    ## --- duplicate keys (reject, via the recursive dup path) ---
    list(name = "dup_toplevel", accept = FALSE, dup = TRUE,
         body = '{"ok":true,"ok":true,"persisted":true}'),
    list(name = "dup_nested", accept = FALSE, dup = TRUE,
         body = '{"ok":true,"persisted":true,"x":{"a":1,"a":2}}'),
    ## --- schema violations (reject) ---
    list(name = "extra_key", accept = FALSE,
         body = '{"ok":true,"persisted":true,"extra":1}'),
    list(name = "missing_persisted", accept = FALSE,
         body = '{"ok":true}'),
    list(name = "ok_wrong_type", accept = FALSE,
         body = '{"ok":"true","persisted":true}'),
    list(name = "persisted_wrong_type", accept = FALSE,
         body = '{"ok":true,"persisted":"true"}'),
    list(name = "persisted_false_on_success", accept = FALSE,
         body = '{"ok":true,"persisted":false}'),
    list(name = "error_extra", accept = FALSE,
         body = '{"error":"x","message":"y","ok":false,"z":1}'),
    list(name = "error_missing_message", accept = FALSE,
         body = '{"error":"x","ok":false}'),
    list(name = "error_wrong_type", accept = FALSE,
         body = '{"error":123,"message":"y","ok":false}'),
    ## --- not-well-formed / not-an-object (reject) ---
    list(name = "trailing_content", accept = FALSE,
         body = '{"ok":true,"persisted":true} trailing'),
    list(name = "not_object_array", accept = FALSE, body = "[1,2,3]"),
    list(name = "scalar", accept = FALSE, body = '"scalar"'),
    list(name = "truncated", accept = FALSE, body = '{"ok":true,"persisted":true'),
    list(name = "empty_object", accept = FALSE, body = "{}"))
