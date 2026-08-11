#!/bin/bash
# A1 acceptance gates (codex). Run IN the guest as `ubuntu`. rctl runs as the
# unprivileged `canary` principal via sudo -u; privileged inspection uses sudo.
set -uo pipefail
SINK=/var/log/runix/audit.jsonl
U="sudo -u canary"
UNIT=runix-canary.service
SLOW=runix-canary-slow.service
pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
command -v jq >/dev/null || sudo apt-get install -y -qq jq >/dev/null 2>&1

echo "## GATE 1: broker-backed system durability (unprivileged principal)"
cap=$($U rctl capabilities --json)
sda=$(jq -r '.result.audit.system_durable_audit' <<<"$cap")
scope=$(jq -r '.result.audit.audit_scope' <<<"$cap")
echo "  system_durable_audit=$sda audit_scope=$scope"
{ [ "$sda" = true ] && [ "$scope" = system ]; } && ok "G1" || no "G1"

echo "## GATE 7: an unrelated unit is denied (negative authorization)"
den=$($U rctl services restart systemd-journald.service --json); dc=$?
dcls=$(jq -r '.error.class[0]' <<<"$den")
echo "  ok=$(jq -r .ok <<<"$den") class=$dcls exit=$dc"
{ [ "$(jq -r .ok <<<"$den")" = false ] && [ "$dcls" = runix_unauthorized ] && \
  [ "$dc" -eq 1 ]; } && ok "G7" || no "G7"

echo "## GATE 2: preview makes no effect"
inv0=$($U rctl services info $UNIT --json | jq -r '.result.invocation_id')
prev=$($U rctl services restart $UNIT --preview --json)
pflag=$(jq -r '.result.preview' <<<"$prev")
inv1=$($U rctl services info $UNIT --json | jq -r '.result.invocation_id')
echo "  preview=$pflag inv_before=$inv0 inv_after=$inv1"
{ [ "$pflag" = true ] && [ "$inv0" = "$inv1" ]; } && ok "G2" || no "G2"

echo "## GATE 3: restart advances InvocationID, verified post-state"
res=$($U rctl services restart $UNIT --json)
rok=$(jq -r .ok <<<"$res")
ib=$(jq -r '.result.completion.invocation_before' <<<"$res")
ia=$(jq -r '.result.completion.invocation_after' <<<"$res")
cid=$(jq -r '.result.correlation_id' <<<"$res")
act=$(jq -r '.result.audit.actor' <<<"$res")
echo "  ok=$rok method=$(jq -r '.result.completion.method' <<<"$res") inv:$ib->$ia actor=$act"
{ [ "$rok" = true ] && [ -n "$ia" ] && [ "$ia" != "$ib" ] && [ "$ia" != null ]; } \
  && ok "G3" || no "G3"

echo "## GATE 4: durable intent+outcome, same cid, unprivileged actor uid:1001"
sleep 1
recs=$(sudo grep -F "$cid" "$SINK")
ni=$(jq -rs '[.[]|select(.phase=="intent")]|length' <<<"$recs")
noo=$(jq -rs '[.[]|select(.phase=="outcome")]|length' <<<"$recs")
ra=$(jq -rs '[.[]|select(.phase=="intent")][0].actor' <<<"$recs")
rp=$(jq -rs '[.[]|select(.phase=="intent")][0].broker.peer.uid' <<<"$recs")
echo "  intent=$ni outcome=$noo actor=$ra broker.peer.uid=$rp"
{ [ "$ni" -ge 1 ] && [ "$noo" -ge 1 ] && [ "$ra" = "uid:1001" ] && \
  [ "$rp" = 1001 ]; } && ok "G4" || no "G4"

echo "## GATE 5: timeout -> audited error carrying observed state"
sudo systemctl stop $SLOW 2>/dev/null || true
sudo systemctl reset-failed $SLOW 2>/dev/null || true
to=$($U rctl services restart $SLOW --timeout=3 --json); tc=$?
tcls=$(jq -r '.error.class[0]' <<<"$to")
tobs=$(jq -r '.error.observed.active_state' <<<"$to")
tcid=$(jq -r '.error.correlation_id' <<<"$to")
echo "  class=$tcls observed.active_state=$tobs exit=$tc"
sleep 1
tout=$(sudo grep -F "$tcid" "$SINK" 2>/dev/null | \
  jq -rs '[.[]|select(.phase=="outcome" and .outcome=="timeout")]|length')
echo "  audited timeout outcome records=$tout"
{ [ "$tcls" = runix_timeout ] && [ -n "$tobs" ] && [ "$tobs" != null ] && \
  [ "${tout:-0}" -ge 1 ]; } && ok "G5" || no "G5"

echo "## GATE 6: hard death -> open intent detectable across broker restart"
sudo systemctl stop $SLOW 2>/dev/null || true
sudo systemctl reset-failed $SLOW 2>/dev/null || true
$U rctl services restart $SLOW --timeout=60 --json >/tmp/g6.out 2>&1 &
sleep 3
sudo pkill -9 -u canary 2>/dev/null || true
sleep 1
opencid=$(sudo cat "$SINK" | jq -rs '
  [.[]|select(.phase=="intent" or .phase=="outcome")] as $a
  | ($a|map(select(.phase=="outcome").correlation_id)) as $out
  | ($a|map(select(.phase=="intent"))|last) as $li
  | if $li and ($out|index($li.correlation_id)|not) then $li.correlation_id else empty end')
echo "  open intent cid (pre broker-restart): ${opencid:-<none>}"
sudo systemctl restart runix-audit.socket 2>/dev/null || true
still=$(sudo grep -F "${opencid:-__none__}" "$SINK" 2>/dev/null | \
  jq -rs '[.[]|select(.phase=="intent")]|length')
echo "  intent still present after broker restart: ${still:-0}"
{ [ -n "$opencid" ] && [ "${still:-0}" -ge 1 ]; } \
  && ok "G6 (detectability, not recovery)" || no "G6"
sudo systemctl stop $SLOW 2>/dev/null || true

echo
echo "==== A1 gates: $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
