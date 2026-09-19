# Input: redacted audit records. $calls: non-secret per-gate result records.
def require($ok; $why): if $ok then . else error($why) end;
def specifications:
  [ ["G1", "issuer", "apt.update", "ok", "true", "persisted", 0],
    ["G2", "issuer", "apt.update", "operation_failed", "true", "persisted", 0],
    ["G3", "issuer", "apt.install", "ok", "true", "persisted", 0],
    ["G4", "issuer", "apt.remove", "ok", "true", "persisted", 0],
    ["G5", "issuer", "apt.upgrade", "ok", "true", "persisted", 0],
    ["G8-hold", "issuer", "apt.hold", "ok", "true", "persisted", 0],
    ["G8-unhold", "issuer", "apt.unhold", "ok", "true", "persisted", 0],
    ["G9", "issuer", "apt.remove", "protected_package", "false", "preview_refused", 0],
    ["G-OWN", "issuer", "apt.hold", "package_not_owned", "false", "preview_refused", 0],
    ["G10", "issuer", "apt.update", "apt_locked", "false", "persisted", 0],
    ["G12", "oracle", "apt.update", "no_intent", "false", "persisted", 0],
    ["G13", "oracle", "apt.update", "ok", "true", "persisted", 0],
    ["G14", "oracle", "apt.update", "no_intent", "false", "persisted", 0],
    ["G15", "oracle", "apt.update", "internal", "false", "persisted", 0],
    ["G-INT", "issuer", "apt.install", "unknown", "unknown", "open", 3],
    ["G6", "issuer", "apt.install", "dpkg_broken", "true", "persisted", 0],
    ["G7", "issuer", "apt.configure", "dpkg_broken", "true", "persisted", 0],
    ["G-INLINE", "issuer", "apt.update", "ok", "true", "persisted", 0] ];
def package_state($package):
  [.observed | to_entries[] | select(.key | startswith($package + ":")) | .value]
  | if length == 1 then .[0] else error("missing/ambiguous observed package " + $package) end;
def post_state($c):
  . as $r
  | require(.observed_failed == false; $c.gate + ": observation failed/missing")
  | require(.authorized_via == (if ($c.verb == "apt.update" or $c.verb == "apt.hold")
      then "autonomous" else "pkcheck" end); $c.gate + ": authorization provenance")
  | if $c.verb == "apt.update" then
      require(.observed == null and .changed == null and .state_changed == null;
        $c.gate + ": update fabricated post-state")
    else
      require((.observed | type) == "object" and .changed == ($c.status == "ok")
        and .state_changed == ($c.gate != "G7"); $c.gate + ": verdict or state diff")
      | (if ($c.gate == "G6" or $c.gate == "G7") then "canary-badpost" else "canary-benign" end) as $pkg
      | ($r | package_state($pkg)) as $s
      | require(
          if ($c.gate == "G3" or $c.gate == "G5") then
            $s.status == "installed" and $s.version == "1.1"
          elif $c.gate == "G4" then
            ($s.status == "not-installed" or $s.status == "config-files")
          elif $c.gate == "G8-hold" then $s.selection == "hold"
          elif $c.gate == "G8-unhold" then $s.selection == "install"
          elif ($c.gate == "G6" or $c.gate == "G7") then
            $s.status == "half-configured" and $s.version == "1.0"
          else false end; $c.gate + ": wrong observed post-state")
    end;
def check_call($c; $audit):
  [$audit[] | select(.correlation_id == $c.cid)] as $records
  | if $c.outcome == "preview_refused" then
      require(($records | length) == 0; $c.gate + ": preview opened an intent")
    else
      require(($c.cid | type) == "string" and ($c.cid | length) > 0 and $c.cid != "-";
        $c.gate + ": missing correlation ID")
      | [$records[] | select(.phase == "intent")] as $intent
      | [$records[] | select(.phase == "outcome")] as $outcome
      | [$records[] | select(.record_type == "broker_receipt")] as $receipts
      | require(($intent | length) == 1 and $intent[0].actor == "uid:1002"
          and $intent[0].operation == $c.verb; $c.gate + ": intent identity")
      | if $c.outcome == "open" then
          require(($outcome | length) == 0 and $receipts[-1].receipt_state == "redeemed";
            $c.gate + ": interrupted intent was not redeemed and left open")
        else
          require(($outcome | length) == 1 and $outcome[0].actor == "uid:1002"
            and $outcome[0].operation == $c.verb
            and $outcome[0].effect_issued == ($c.effect == "true")
            and $outcome[0].outcome == (if $c.status == "ok" then "ok" else "error" end);
            $c.gate + ": durable outcome mismatch")
          | require($receipts[-1].receipt_state == (if $c.effect == "true" then "redeemed" else "issued" end);
              $c.gate + ": receipt state mismatch")
          | if $c.backend == "issuer" then $outcome[0] | post_state($c) else . end
        end
    end;
def check_refusal($c; $audit):
  require(($c | keys) == ["cid","effect_issued","effect_session_opened","status"]
      and ($c.cid | test("^[A-Za-z0-9_-]+$"))
      and ($c.status == "unauthorized" or $c.status == "approval_required")
      and $c.effect_issued == "false" and $c.effect_session_opened == "false";
      "P4: invalid machine refusal")
  | [$audit[] | select(.correlation_id == $c.cid)] as $records
  | [$records[] | select(.phase == "intent")] as $intent
  | [$records[] | select(.phase == "outcome")] as $outcome
  | require(($records | length) == 2 and ($intent | length) == 1
      and ($outcome | length) == 1
      and all($records[]; .actor == "uid:1002" and .operation == "apt.install"
        and .effect_issued == false)
      and $intent[0].outcome == "intent" and $outcome[0].outcome == $c.status;
      "P4: missing refusal audit, wrong identity, or unexpected receipt");
. as $audit
| require(length > 0; "empty audit export")
| require(all(.[];
    if .phase != null then
      (keys - ["correlation_id","actor","phase","operation","outcome","effect_issued",
        "observed","changed","state_changed","observed_failed","authorized_via"] | length) == 0
    elif .record_type == "broker_receipt" then
      (keys - ["record_type","correlation_id","receipt_state"] | length) == 0
    else keys == ["record_type"] end); "unredacted audit fields")
| specifications as $specs
| require(($refusals | length) == 2 and ([$refusals[].cid] | unique | length) == 2;
    "P4: missing or reused refusal correlation ID")
| reduce $refusals[] as $r (. ; check_refusal($r; $audit))
| require(($calls | length) == ($specs | length); "missing or extra gate result")
| require(([$calls[] | select(.outcome != "preview_refused") | .cid] | length)
    == ([$calls[] | select(.outcome != "preview_refused") | .cid] | unique | length);
    "correlation ID reused across gates")
| [ $specs[] as $s
    | [$calls[] | select(.gate == $s[0])] as $found
    | require(($found | length) == 1; $s[0] + ": missing/duplicate result")
    | $found[0] as $c
    | require([$c.gate,$c.backend,$c.verb,$c.status,$c.effect,$c.outcome,$c.rc] == $s;
        $s[0] + ": result contract mismatch")
    | check_call($c; $audit)
    | $s[0] ]
| {verified_gates: ., count: length, verified_machine_refusals: 2}
