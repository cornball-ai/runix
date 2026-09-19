# Synthetic records only. Independent examples of the gate contracts; never run
# against the broker. Negative tests corrupt these fixtures before validation.
def call($g;$v;$s;$e): {gate:$g,backend:"issuer",verb:$v,status:$s,effect:$e,
  outcome:"persisted",rc:0,cid:("fixture-"+$g)};
[
 call("G1";"apt.update";"ok";"true"),
 call("G2";"apt.update";"operation_failed";"true"),
 call("G3";"apt.install";"ok";"true"),
 call("G4";"apt.remove";"ok";"true"),
 call("G5";"apt.upgrade";"ok";"true"),
 call("G8-hold";"apt.hold";"ok";"true"),
 call("G8-unhold";"apt.unhold";"ok";"true"),
 (call("G9";"apt.remove";"protected_package";"false") | .outcome="preview_refused"),
 (call("G-OWN";"apt.hold";"package_not_owned";"false") | .outcome="preview_refused"),
 call("G10";"apt.update";"apt_locked";"false"),
 (call("G12";"apt.update";"no_intent";"false") | .backend="oracle"),
 (call("G13";"apt.update";"ok";"true") | .backend="oracle"),
 (call("G14";"apt.update";"no_intent";"false") | .backend="oracle"),
 (call("G15";"apt.update";"internal";"false") | .backend="oracle"),
 (call("G-INT";"apt.install";"unknown";"unknown") | .outcome="open" | .rc=3),
 call("G6";"apt.install";"dpkg_broken";"true"),
 call("G7";"apt.configure";"dpkg_broken";"true"),
 call("G-INLINE";"apt.update";"ok";"true")
] as $calls
| {calls:$calls,audit:[ $calls[] | select(.outcome != "preview_refused") | . as $c
  | {correlation_id:.cid,actor:"uid:1002",phase:"intent",operation:.verb,outcome:"intent"},
    {record_type:"broker_receipt",correlation_id:.cid,
      receipt_state:(if .effect == "false" then "issued" else "redeemed" end)},
    (select(.outcome != "open")
    | {correlation_id:.cid,actor:"uid:1002",phase:"outcome",operation:.verb,
        outcome:(if .status == "ok" then "ok" else "error" end),effect_issued:(.effect=="true"),
        observed_failed:false,
        authorized_via:(if (.verb=="apt.update" or .verb=="apt.hold") then "autonomous" else "pkcheck" end),
        observed:null,changed:null,state_changed:null}
    | if ($c.gate == "G3" or $c.gate == "G5") then
        .observed={"canary-benign:all":{status:"installed",version:"1.1"}} | .changed=true | .state_changed=true
      elif $c.gate == "G4" then
        .observed={"canary-benign:all":{status:"not-installed",version:""}} | .changed=true | .state_changed=true
      elif $c.gate == "G8-hold" then
        .observed={"canary-benign:all":{selection:"hold"}} | .changed=true | .state_changed=true
      elif $c.gate == "G8-unhold" then
        .observed={"canary-benign:all":{selection:"install"}} | .changed=true | .state_changed=true
      elif ($c.gate == "G6" or $c.gate == "G7") then
        .observed={"canary-badpost:all":{status:"half-configured",version:"1.0"}}
        | .changed=false | .state_changed=($c.gate=="G6")
      else . end)
]}
| .refusals = [
    {cid:"fixture-P4-before",status:"approval_required",effect_issued:"false",effect_session_opened:"false"},
    {cid:"fixture-P4-after",status:"approval_required",effect_issued:"false",effect_session_opened:"false"}]
| .audit += [.refusals[] |
    {correlation_id:.cid,actor:"uid:1002",phase:"intent",operation:"apt.install",
      outcome:"intent",effect_issued:false},
    {correlation_id:.cid,actor:"uid:1002",phase:"outcome",operation:"apt.install",
      outcome:"approval_required",effect_issued:false}]
