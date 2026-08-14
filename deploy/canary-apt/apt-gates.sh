#!/bin/bash
# §7 apt-mutation acceptance gates (libapt-pkg-helper-plan.md §7) inside the guest.
# Run as `ubuntu`. Drives the NATIVE helper boundary via the two VM-only oracles:
#   pkgexec-plan  (root): the issue-time digest source (resource + plan_hash)
#   rab-exercise  (aptbot): the one-process open->helper->outcome lifecycle
# Native observations only (dpkg-query, the audit sink); no R stack, so this proves
# the native helper boundary, not the future pkgops integration.
#
# Autonomous verbs (update/hold) run as aptbot directly. Every OTHER verb — unhold
# included — is gated, so it follows codex's rule: the default-denial matrix is
# proven first (polkit-matrix.sh), then a TEMPORARY guest-only rule grants aptbot
# ONLY the needed action for one gate, recorded and removed+verified afterward.
set -uo pipefail
SOCK=/run/runix-audit.sock
SINK=/var/log/runix/audit.jsonl
ACT=ai.cornball.runix.apt
LIBX=/usr/libexec/pkgexec
REPO=/srv/canary-repo
TEMPRULE=/etc/polkit-1/rules.d/49-canary-apt-temp.rules
BROKENSRC=/etc/apt/sources.list.d/canary-broken.sources
DRIFTSRC=/etc/apt/sources.list.d/canary-drift.sources
PIN=/etc/apt/preferences.d/99-canary-g5-pin
ZERO=0000000000000000000000000000000000000000000000000000000000000000
LOCKPID=""
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
no() { echo "  FAIL  $1 ($2)"; fail=$((fail + 1)); }
command -v jq >/dev/null || sudo apt-get install -y -qq jq >/dev/null 2>&1

# Refuse to run on top of a stale temporary grant — it could taint the matrix.
if [ -e "$TEMPRULE" ]; then
    echo "REFUSING: a stale temp polkit rule exists ($TEMPRULE); remove it first" >&2
    exit 1
fi

cleanup() {
    [ -n "$LOCKPID" ] && { kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null; }
    sudo rm -f "$BROKENSRC" "$DRIFTSRC" "$PIN" 2>/dev/null || true
    if [ -e "$TEMPRULE" ]; then
        sudo rm -f "$TEMPRULE"; sudo systemctl restart polkit 2>/dev/null; sleep 1
    fi
}
trap cleanup EXIT

grant() { # action-suffix
    sudo tee "$TEMPRULE" >/dev/null <<EOF
// TEMPORARY canary-apt gate grant (added + removed by apt-gates.sh; recorded in
// the run log). Grants aptbot ONLY $ACT.$1 for the duration of one gate.
polkit.addRule(function(action, subject) {
    if (action.id == "$ACT.$1" && subject.user == "aptbot") {
        return polkit.Result.YES;
    }
});
EOF
    sudo systemctl restart polkit
    sleep 1
    echo "  [temp-grant] +$ACT.$1 (aptbot)"
}
ungrant() {
    if [ -e "$TEMPRULE" ]; then
        sudo rm -f "$TEMPRULE"
        sudo systemctl restart polkit
        sleep 1
        [ -e "$TEMPRULE" ] && echo "  [temp-grant] FAILED to remove" >&2 \
            || echo "  [temp-grant] removed + verified gone"
    fi
}

field() { grep -oE "$1=[^ ]*" <<<"$2" | head -1 | cut -d= -f2-; }
do_plan() { # verb [pkgs...] -> PH, PR, PRC
    local out
    out=$(sudo pkgexec-plan "$@" 2>/dev/null)
    PRC=$?
    PH=$(grep -oE '^plan_hash=.*' <<<"$out" | cut -d= -f2)
    PR=$(grep -oE '^resource=.*' <<<"$out" | cut -d= -f2-)
}
do_ex() { # [--replay] <verb> <resource> <hash> [pkgs...] -> EXRC,EXSTATUS,EXDETAIL,EXEFFECT,EXOUTCOME,EXCID,EXREPLAY
    local args=()
    if [ "${1:-}" = "--replay" ]; then args+=(--replay); shift; fi
    args+=("$SOCK" "$@")
    local out line
    out=$(sudo -u aptbot rab-exercise "${args[@]}" 2>/dev/null)
    EXRC=$?
    line=$(grep '^RESULT ' <<<"$out" | head -1)
    EXCID=$(field cid "$line"); EXSTATUS=$(field status "$line")
    EXDETAIL=$(field detail "$line"); EXEFFECT=$(field effect_issued "$line")
    EXOUTCOME=$(field outcome "$line"); EXREPLAY=$(field replay "$line")
}
dpkg_state() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null; }
dpkg_ver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null; }
# Pin every CURRENTLY-upgradable package EXCEPT canary-benign to its installed
# version, so a whole-system apt.upgrade is isolated to the canary 1.0->1.1
# transition (the base cloud image carries unrelated pending upgrades). Enumerated
# from the SAME cache the effector reads, so plan and commit agree. Removed by
# unpin_others and, as a safety net, in the cleanup trap.
pin_others() {
    : | sudo tee "$PIN" >/dev/null
    local pkg ver
    while read -r pkg; do
        { [ -z "$pkg" ] || [ "$pkg" = canary-benign ]; } && continue
        ver=$(dpkg_ver "$pkg")
        [ -n "$ver" ] || continue
        printf 'Package: %s\nPin: version %s\nPin-Priority: 1001\n\n' "$pkg" "$ver" \
            | sudo tee -a "$PIN" >/dev/null
    done < <(apt list --upgradable 2>/dev/null | awk -F/ 'NR>1 {print $1}')
}
unpin_others() { sudo rm -f "$PIN"; }
# Kill a pid and ALL its descendants deepest-first (so dpkg/postinst cannot outlive
# the entrypoint and complete the install), as root. Used to interrupt the whole
# helper transaction subtree (pkexec down) while leaving rab-exercise (its parent) alive.
kill_subtree() {
    local pid="$1" kid
    { [ -z "$pid" ] || [ "$pid" -le 1 ]; } 2>/dev/null && return 0
    for kid in $(pgrep -P "$pid" 2>/dev/null); do kill_subtree "$kid"; done
    sudo kill -9 "$pid" 2>/dev/null || true
}
direct_pkexec() { # verb-path json -> sets DST, DEF, DDT
    local out
    out=$(printf '%s' "$2" | sudo -u aptbot pkexec "$1" 2>/dev/null)
    DST=$(jq -r 'if (.status|type)=="string" then .status else "" end' <<<"$out" 2>/dev/null)
    # explicit boolean presence/type check: `.effect_issued // ""` would swallow a
    # JSON false (jq's // treats false as empty), so false stays "false" here.
    DEF=$(jq -r 'if (.effect_issued|type)=="boolean" then (.effect_issued|tostring) else "" end' <<<"$out" 2>/dev/null)
    DDT=$(jq -r 'if (.detail|type)=="string" then .detail else "" end' <<<"$out" 2>/dev/null)
}
audit_intent_outcome() { # cid label
    sleep 1
    local recs ni no act
    recs=$(sudo grep -F "$1" "$SINK" 2>/dev/null)
    ni=$(jq -rs '[.[]|select(.phase=="intent")]|length' <<<"$recs" 2>/dev/null)
    no=$(jq -rs '[.[]|select(.phase=="outcome")]|length' <<<"$recs" 2>/dev/null)
    act=$(jq -rs '[.[]|select(.phase=="intent")][0].actor' <<<"$recs" 2>/dev/null)
    { [ "${ni:-0}" -ge 1 ] && [ "${no:-0}" -ge 1 ] && [ "$act" = "uid:1002" ]; } \
        && ok "$2 audit: intent+outcome, actor=$act" \
        || no "$2 audit" "intent=$ni outcome=$no actor=$act"
}

echo "########## G1: update good-source -> applied, durable audit ##########"
do_plan apt.update
if [ "$PRC" = 0 ] && [ -n "$PH" ]; then
    do_ex apt.update "" "$PH"
    { [ "$EXSTATUS" = ok ] && [ "$EXEFFECT" = true ] && [ "$EXOUTCOME" = persisted ]; } \
        && ok "G1 update applied" || no "G1 update" "status=$EXSTATUS eff=$EXEFFECT out=$EXOUTCOME"
    audit_intent_outcome "$EXCID" "G1"
else
    no "G1 plan" "exit=$PRC hash='$PH'"
fi

echo "########## G2: update bad-source -> operation_failed (Error-Mode=any) ##########"
sudo tee "$BROKENSRC" >/dev/null <<EOF
Types: deb
URIs: http://127.0.0.1:9/nope
Suites: ./
Trusted: yes
Enabled: yes
EOF
do_plan apt.update
do_ex apt.update "" "$PH"
{ [ "$EXSTATUS" = operation_failed ] && [ "$EXEFFECT" = true ]; } \
    && ok "G2 bad-source -> operation_failed" || no "G2" "status=$EXSTATUS eff=$EXEFFECT"
sudo rm -f "$BROKENSRC"

echo "########## G3: benign install (temp-grant) -> applied ##########"
grant install
sudo apt-get remove -y canary-benign >/dev/null 2>&1 || true
do_plan apt.install canary-benign
do_ex apt.install "$PR" "$PH" canary-benign
{ [ "$EXSTATUS" = ok ] && [ "$EXEFFECT" = true ]; } \
    && ok "G3 install status ok" || no "G3 install" "status=$EXSTATUS eff=$EXEFFECT"
dpkg_state canary-benign | grep -q "install ok installed" \
    && ok "G3 canary-benign installed (native)" || no "G3 dpkg" "$(dpkg_state canary-benign)"
audit_intent_outcome "$EXCID" "G3"
ungrant

echo "########## G4: benign remove (temp-grant) -> applied ##########"
grant remove
do_plan apt.remove canary-benign
do_ex apt.remove "$PR" "$PH" canary-benign
{ [ "$EXSTATUS" = ok ] && [ "$EXEFFECT" = true ]; } \
    && ok "G4 remove status ok" || no "G4 remove" "status=$EXSTATUS eff=$EXEFFECT"
dpkg_state canary-benign | grep -q "install ok installed" \
    && no "G4 dpkg" "still installed" || ok "G4 canary-benign removed (native)"
ungrant

echo "########## G5: whole-system upgrade (temp-grant) 1.0 -> 1.1 ##########"
grant upgrade
# Setup + PROVE it: install canary-benign 1.0 and assert it BEFORE planning, so a
# silently failed fixture install surfaces here (as the precondition) rather than
# later as an unexplained empty post-upgrade version.
sudo apt-get install -y --allow-downgrades canary-benign=1.0 >/dev/null 2>&1
[ "$(dpkg_ver canary-benign)" = 1.0 ] \
    && ok "G5 setup: canary-benign == 1.0 before upgrade" \
    || no "G5 setup" "ver=$(dpkg_ver canary-benign) (expected 1.0)"
# Isolate the whole-system upgrade to the canary transition: pin every OTHER
# upgradable package to its installed version (removed below and in the trap).
pin_others
# Assert the SIMULATED whole-system upgrade (same FORBID_REMOVE semantics as the
# effector's apt.upgrade) is EXACTLY canary-benign 1.0->1.1 and nothing else.
SIM=$(apt-get -s upgrade --with-new-pkgs 2>/dev/null | grep -E '^(Inst|Remv|Purg) ')
CBLINE=$(grep -E '^Inst canary-benign \[1\.0\] \(1\.1' <<<"$SIM")
OTHER=$(grep -vE '^Inst canary-benign ' <<<"$SIM" | grep -E '^(Inst|Remv|Purg) ')
{ [ -n "$CBLINE" ] && [ -z "$OTHER" ]; } \
    && ok "G5 plan: only canary-benign 1.0->1.1, no unrelated changes" \
    || no "G5 plan" "cb='$CBLINE' other='$(tr '\n' ';' <<<"$OTHER")'"
# Run the real helper over the isolated transaction.
do_plan apt.upgrade
do_ex apt.upgrade "$PR" "$PH"
{ [ "$EXSTATUS" = ok ] && [ "$EXEFFECT" = true ]; } \
    && ok "G5 upgrade status ok" || no "G5 upgrade" "status=$EXSTATUS eff=$EXEFFECT"
[ "$(dpkg_ver canary-benign)" = 1.1 ] \
    && ok "G5 canary-benign upgraded to 1.1 (native)" || no "G5 dpkg" "ver=$(dpkg_ver canary-benign)"
unpin_others
ungrant

echo "########## G8: hold (autonomous) then unhold (temp-grant), selection read-back ##########"
sudo apt-get install -y canary-benign >/dev/null 2>&1
do_plan apt.hold canary-benign
do_ex apt.hold "$PR" "$PH" canary-benign
sel=$(dpkg_state canary-benign | awk '{print $1}')
{ [ "$EXSTATUS" = ok ] && [ "$sel" = hold ]; } \
    && ok "G8 hold applied, selection=$sel" || no "G8 hold" "status=$EXSTATUS sel=$sel"
grant unhold  # unhold is NOT autonomous
do_plan apt.unhold canary-benign
do_ex apt.unhold "$PR" "$PH" canary-benign
sel=$(dpkg_state canary-benign | awk '{print $1}')
{ [ "$EXSTATUS" = ok ] && [ "$sel" = install ]; } \
    && ok "G8 unhold applied, selection=$sel" || no "G8 unhold" "status=$EXSTATUS sel=$sel"
ungrant

echo "########## G9: protected removal refused before the receipt is spent ##########"
grant remove
do_ex apt.remove canary-protected "$ZERO" canary-protected
{ [ "$EXSTATUS" = protected_package ] && [ "$EXEFFECT" = false ]; } \
    && ok "G9 protected removal refused" || no "G9" "status=$EXSTATUS eff=$EXEFFECT"
dpkg_state canary-protected | grep -q "install ok installed" \
    && ok "G9 canary-protected still installed" || no "G9 dpkg" "$(dpkg_state canary-protected)"
ungrant

echo "########## G-OWN: rapt-owned package refused (ownership, autonomous hold) ##########"
# r-cornball-canary matches ^r-[a-z]+-[a-z0-9.]+$ -> package_not_owned before redeem.
# hold is autonomous, so no grant is needed; a placeholder hash is never checked (the
# ownership refusal precedes redemption).
do_ex apt.hold r-cornball-canary "$ZERO" r-cornball-canary
{ [ "$EXSTATUS" = package_not_owned ] && [ "$EXEFFECT" = false ]; } \
    && ok "G-OWN rapt-owned hold refused" || no "G-OWN" "status=$EXSTATUS eff=$EXEFFECT"

echo "########## G10: dpkg-lock contention -> apt_locked (fcntl lock-holder) ##########"
do_plan apt.update
LOCKOUT=$(mktemp)
sudo /usr/local/bin/fcntl-lock /var/lib/apt/lists/lock 20 >"$LOCKOUT" 2>&1 &
LOCKPID=$!
for _ in $(seq 1 20); do grep -q '^locked' "$LOCKOUT" 2>/dev/null && break; sleep 0.5; done
grep -q '^locked' "$LOCKOUT" && ok "G10 fcntl lock held (excludes GetLock)" \
    || no "G10 lock-holder" "did not acquire the lock"
do_ex apt.update "" "$PH"
{ [ "$EXSTATUS" = apt_locked ] && [ "$EXEFFECT" = false ]; } \
    && ok "G10 lock contention -> apt_locked" || no "G10" "status=$EXSTATUS eff=$EXEFFECT"
kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null || true; LOCKPID=""; rm -f "$LOCKOUT"

echo "########## G11a: MISSING receipt (no field) -> schema refusal ##########"
FAKECID=00000000000000000001-0123456789abcdef
direct_pkexec "$LIBX/runix-apt-update" \
    "$(printf '{"correlation_id":"%s","plan_schema":1,"packages":[],"lock_timeout":30}' "$FAKECID")"
{ [ "$DST" = internal ] && [ "$DEF" = false ]; } \
    && ok "G11a missing receipt -> internal (detail=$DDT)" || no "G11a" "status=$DST eff=$DEF detail=$DDT"

echo "########## G11b: INVALID receipt (well-formed, never issued) -> no_intent ##########"
direct_pkexec "$LIBX/runix-apt-update" \
    "$(printf '{"effect_receipt":"%s","correlation_id":"%s","plan_schema":1,"packages":[],"lock_timeout":30}' "$(openssl rand -hex 16)" "$FAKECID")"
{ [ "$DST" = no_intent ] && [ "$DEF" = false ] && [ "$DDT" = receipt_invalid ]; } \
    && ok "G11b invalid receipt -> no_intent (detail=receipt_invalid)" || no "G11b" "status=$DST eff=$DEF detail=$DDT"

echo "########## G12: mismatched receipt (wrong bound hash) -> no_intent/receipt_mismatch ##########"
do_ex apt.update "" "1111111111111111111111111111111111111111111111111111111111111111"
{ [ "$EXSTATUS" = no_intent ] && [ "$EXDETAIL" = receipt_mismatch ] && [ "$EXEFFECT" = false ]; } \
    && ok "G12 mismatched receipt -> no_intent (detail=receipt_mismatch)" \
    || no "G12" "status=$EXSTATUS detail=$EXDETAIL eff=$EXEFFECT"

echo "########## G13: replay a redeemed receipt -> single-use rejected ##########"
do_plan apt.update
do_ex --replay apt.update "" "$PH"
{ [ "$EXSTATUS" = ok ] && [ "$EXEFFECT" = true ] && [ "$EXREPLAY" = rejected ]; } \
    && ok "G13 replay rejected (receipt_redeemed at the boundary)" \
    || no "G13" "status=$EXSTATUS eff=$EXEFFECT replay=$EXREPLAY rc=$EXRC"

echo "########## G14: plan drift (source set changed post-issue) -> receipt_mismatch ##########"
do_plan apt.update
sudo tee "$DRIFTSRC" >/dev/null <<EOF
Types: deb
URIs: file:///srv/canary-repo-2
Suites: ./
Trusted: yes
Enabled: yes
EOF
do_ex apt.update "" "$PH"
{ [ "$EXSTATUS" = no_intent ] && [ "$EXDETAIL" = receipt_mismatch ] && [ "$EXEFFECT" = false ]; } \
    && ok "G14 plan drift -> receipt_mismatch" || no "G14" "status=$EXSTATUS detail=$EXDETAIL eff=$EXEFFECT"
sudo rm -f "$DRIFTSRC"

echo "########## G15: entrypoint isolation (a package arg is REJECTED by update) ##########"
sudo apt-get remove -y canary-benign >/dev/null 2>&1 || true
do_plan apt.update
do_ex apt.update "" "$PH" canary-benign  # update's arity is 0; a package is a schema refusal
{ [ "$EXSTATUS" = internal ] && [ "$EXEFFECT" = false ]; } \
    && ok "G15 update rejects a package arg (status=internal, no effect)" \
    || no "G15 rejection" "status=$EXSTATUS eff=$EXEFFECT"
dpkg_state canary-benign | grep -q "install ok installed" \
    && no "G15 dpkg" "update installed a package" || ok "G15 canary-benign absent (no install)"

echo "########## G-INT: interrupted transaction (kill the commit subtree mid-postinst) ##########"
grant install
sudo rm -f /run/canary-slow.marker
do_plan apt.install canary-slow
INTOUT=$(mktemp)
sudo -u aptbot rab-exercise "$SOCK" apt.install "$PR" "$PH" canary-slow >"$INTOUT" 2>&1 &
BGPID=$!
# Synchronize on the postinst marker: it appears only AFTER redeem + unpack, while
# the configure (postinst) is mid-run — the real post-redeem interruption window.
MARKED=0
for _ in $(seq 1 120); do [ -e /run/canary-slow.marker ] && { MARKED=1; break; }; sleep 0.5; done
# The pkexec-spawned privileged helper is reparented under polkitd — it is NOT a
# child of the pkexec client, so killing the client leaves dpkg running to
# completion (the transaction finishes and records outcome=ok). Locate the EXACT
# privileged process by /proc/<pid>/exe and require exactly one root-owned match,
# then kill ITS descendant tree deepest-first (dpkg -> postinst -> sleep) and the
# helper itself — never the client. rab-exercise (the parent) stays alive.
helpers_now() { # print each root-owned pid whose exe is the install entrypoint
    local p exe u
    for p in $(pgrep -f "$LIBX/runix-apt-install" 2>/dev/null); do
        exe=$(sudo readlink -f "/proc/$p/exe" 2>/dev/null)
        u=$(sudo awk '/^Uid:/{print $2; exit}' "/proc/$p/status" 2>/dev/null)
        [ "$exe" = "$LIBX/runix-apt-install" ] && [ "$u" = 0 ] && echo "$p"
    done
}
mapfile -t HELPERS < <(helpers_now)
[ "${#HELPERS[@]}" -eq 1 ] \
    && ok "G-INT one root helper located (pid ${HELPERS[0]}, /proc/exe=$LIBX/runix-apt-install)" \
    || no "G-INT locate" "expected exactly 1 root-owned helper, found ${#HELPERS[@]}"
PKPID=${HELPERS[0]:-}
[ -n "$PKPID" ] && kill_subtree "$PKPID"
# Verify the ENTIRE transaction subtree is gone before evaluating the outcome.
SUBGONE=0
for _ in $(seq 1 40); do
    [ -z "$(helpers_now)" ] && { SUBGONE=1; break; }
    sleep 0.25
done
[ "$SUBGONE" -eq 1 ] && ok "G-INT transaction subtree gone before evaluation" \
    || no "G-INT subtree" "a root-owned helper survived the kill"
wait "$BGPID" 2>/dev/null; INTRC=$?
iline=$(grep '^RESULT ' "$INTOUT" | head -1); icid=$(field cid "$iline"); iout=$(field outcome "$iline")
rm -f "$INTOUT"
[ "$MARKED" -eq 1 ] && ok "G-INT postinst reached (redeem done, commit in progress)" \
    || no "G-INT sync" "postinst marker never appeared"
{ [ "$iout" = open ] && [ "$INTRC" -eq 3 ]; } \
    && ok "G-INT helper subtree killed -> intent left open (rc=$INTRC)" || no "G-INT open" "outcome=$iout rc=$INTRC"
sleep 1
recs=$(sudo grep -F "$icid" "$SINK" 2>/dev/null)
noo=$(jq -rs '[.[]|select(.phase=="outcome")]|length' <<<"$recs" 2>/dev/null)
rstate=$(jq -rs '[.[]|select(.record_type=="broker_receipt")]|last|.state // "none"' <<<"$recs" 2>/dev/null)
{ [ "$rstate" = redeemed ] && [ "${noo:-0}" -eq 0 ]; } \
    && ok "G-INT receipt redeemed + no outcome (redeemed-no-outcome intent)" \
    || no "G-INT receipt" "receipt_state=$rstate outcome=$noo"
gst=$(dpkg_state canary-slow)
echo "$gst" | grep -qE "half-configured|half-installed|unpacked" \
    && ok "G-INT incomplete dpkg state: '$gst'" || no "G-INT dpkg" "state='$gst' (not incomplete)"
ungrant
sudo dpkg --remove --force-remove-reinstreq canary-slow >/dev/null 2>&1 || true
sudo dpkg --purge canary-slow >/dev/null 2>&1 || true
sudo rm -f /run/canary-slow.marker

echo "########## G6/G7: failed-postinst -> dpkg_broken, then configure (broken) ##########"
grant install
do_plan apt.install canary-badpost
do_ex apt.install "$PR" "$PH" canary-badpost
{ [ "$EXSTATUS" = dpkg_broken ] && [ "$EXEFFECT" = true ]; } \
    && ok "G6 failed-postinst -> dpkg_broken (effect issued)" || no "G6" "status=$EXSTATUS eff=$EXEFFECT"
dpkg_state canary-badpost | grep -q "half-configured" \
    && ok "G6 canary-badpost half-configured (State != NeedsNothing)" || no "G6 dpkg" "$(dpkg_state canary-badpost)"
ungrant
grant configure
do_plan apt.configure
do_ex apt.configure "$PR" "$PH"
{ [ "$EXSTATUS" = dpkg_broken ] && [ "$EXEFFECT" = true ]; } \
    && ok "G7 configure of a still-failing package -> dpkg_broken" || no "G7" "status=$EXSTATUS eff=$EXEFFECT"
ungrant
echo "  [cleanup] removing the deliberately-broken canary-badpost"
sudo dpkg --remove --force-remove-reinstreq canary-badpost >/dev/null 2>&1 || true
sudo dpkg --purge canary-badpost >/dev/null 2>&1 || true

echo
echo "==== §7 apt-mutation gates: $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
