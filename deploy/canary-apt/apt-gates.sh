#!/bin/bash
# §7 apt-mutation acceptance gates (libapt-pkg-helper-plan.md §7) inside the guest.
# Run as `ubuntu`. Drives the REAL pkgops issuer path (VM-gate plan Part B), plus two
# native-boundary oracles for the cases the issuer structurally cannot reach:
#   apt-issue      (aptbot): the pkgops PUBLIC path -- apt_<verb>_preview() recomputes
#                  the plan, then apt_<verb>() commits it (capability -> polkit -> the
#                  effect-session -> the real pkexec entrypoint -> pkgstate verify ->
#                  the durable outcome). EVERY functional gate runs through THIS
#                  (i.e. every gate except G11a/G11b, G12, G13, G14, G15 below).
#   rab-exercise   (aptbot): the broker/receipt oracle, retained ONLY for the gates
#                  that deliberately inject a bad/replayed/stale receipt (G12-G14) or
#                  a forbidden entrypoint argument (G15) -- inputs the pkgops API, which
#                  mints its own receipt and has no package arg for a nullary verb,
#                  cannot express. These prove the native boundary BELOW the issuer.
#   direct pkexec  (aptbot): the receipt-schema gates G11a/G11b call an entrypoint
#                  directly (no receipt lifecycle) to prove its own schema defense.
# The issue-time resource + plan_hash still come from runix-apt-preview (aptbot); the
# gates pass them to apt-issue as EXPECTED values, which it recomputes and compares
# byte-for-byte before committing -- it never trusts a caller-supplied hash.
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
INLINESRC=/etc/apt/sources.list.d/canary-inline.sources
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
# Refuse a stale G5 pin file too: left behind it would suppress unrelated upgrades
# system-wide and mask what a whole-system upgrade actually does.
if [ -e "$PIN" ]; then
    echo "REFUSING: a stale G5 pin file exists ($PIN); remove it first" >&2
    exit 1
fi
# Refuse a stale inline-key source too: left in sources.list.d it joins EVERY
# apt.update digest (an extra source in the plan), silently changing the other update
# gates' hashes and masking exactly what G-INLINE is meant to prove.
if [ -e "$INLINESRC" ]; then
    echo "REFUSING: a stale inline-key source exists ($INLINESRC); remove it first" >&2
    exit 1
fi

cleanup() {
    [ -n "$LOCKPID" ] && { kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null; }
    sudo rm -f "$BROKENSRC" "$DRIFTSRC" "$INLINESRC" "$PIN" 2>/dev/null || true
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
# rec_schema: the record shape the planner emits for a verb (decode_records in
# preview.cc). Sets RKEYS (the EXACT sorted key set of each record), RARR (array-typed
# keys) and ROBJ (object-typed keys); every other key must be a string. update ->
# source records; install/remove/purge/upgrade/dist_upgrade -> transaction records;
# hold/unhold -> selection records; configure -> pending-config records.
rec_schema() { # verb
    case "$1" in
        apt.update)
            RKEYS='["components","options","suite","uri"]'; RARR='["components"]'; ROBJ='["options"]' ;;
        apt.install|apt.remove|apt.purge|apt.upgrade|apt.dist_upgrade)
            RKEYS='["action","architecture","flags","from_version","package","to_version"]'
            RARR='["flags"]'; ROBJ='[]' ;;
        apt.hold|apt.unhold)
            RKEYS='["from_state","package","to_state"]'; RARR='[]'; ROBJ='[]' ;;
        apt.configure)
            RKEYS='["architecture","current_version","package","state"]'; RARR='[]'; ROBJ='[]' ;;
        *) RKEYS='[]'; RARR='[]'; ROBJ='[]' ;;
    esac
}
# pvalidate: STRICT whole-of-contract validation of the last preview response
# ($PPREV/$PRC/$PST) against the REQUEST it answered ($REQ_VERB/$REQ_PKGS_JSON and the
# verb's record schema), BEFORE its hash is ever trusted. Sets PVALID (1/0) + PVMSG,
# fail-closed. It enforces: schema_version 1; status in the nine closed values; the
# EXACT nine-key object (so a MISSING key, which jq would read as null, is rejected as
# firmly as an extra one); verb + packages ECHO the request; resource/detail
# string-or-null; records an array. The plan digest is pinned to the status, not merely
# self-consistent: ok/package_not_owned/held/protected_package MUST carry a digest
# (plan_schema 1, 64-hex hash, >=1 record) and no_op/schema_invalid/resolve_failed/
# dpkg_broken/internal MUST NOT. Each record must have exactly the verb's key set with
# array/object/string types as decoded. Finally exit 0 iff status is ok/no_op.
pvalidate() {
    PVALID=0; PVMSG=""
    local shape
    shape=$(jq -e \
        --arg wv "$REQ_VERB" --argjson wp "$REQ_PKGS_JSON" \
        --argjson rk "$RKEYS" --argjson ra "$RARR" --argjson ro "$ROBJ" '
        (.schema_version==1)
        and (.status|IN("ok","no_op","schema_invalid","resolve_failed","package_not_owned",
              "held","protected_package","dpkg_broken","internal"))
        and (keys==["detail","packages","plan_hash","plan_schema","records",
              "resource","schema_version","status","verb"])
        and (.verb==$wv) and (.packages==$wp)
        and (.resource==null or (.resource|type=="string"))
        and (.detail==null or (.detail|type=="string"))
        and (.records|type=="array")
        and ( if (.status|IN("ok","package_not_owned","held","protected_package"))
              then (.plan_schema==1 and (.plan_hash|type=="string" and test("^[0-9a-f]{64}$"))
                     and (.records|length)>0)
              else (.plan_schema==null and .plan_hash==null and (.records|length)==0)
              end )
        and ( .records|all(
                (keys==$rk)
                and (to_entries|all(
                    if   (.key|IN($ra[])) then (.value|type=="array")
                    elif (.key|IN($ro[])) then (.value|type=="object")
                    else (.value|type=="string") end )) ) )
    ' <<<"$PPREV" >/dev/null 2>&1 && echo 1 || echo 0)
    if [ "$shape" != 1 ]; then PVMSG="response violates the strict contract shape"; return; fi
    case "$PST" in
        ok|no_op) [ "$PRC" -eq 0 ] || { PVMSG="exit $PRC for status=$PST (want 0)"; return; } ;;
        *)        [ "$PRC" -ne 0 ] || { PVMSG="exit 0 for status=$PST (want nonzero)"; return; } ;;
    esac
    PVALID=1
}
# plan_run: fetch the issue-time resource + plan_hash from the PRODUCTION planner
# runix-apt-preview, run UNPRIVILEGED as aptbot (the actor that opens the intent),
# exactly as pkgops will — NOT the root pkgexec-plan diagnostic. One strict JSON
# request in, one strict JSON object out. Records the REQUEST ($REQ_VERB/$REQ_PKGS_*)
# so pvalidate can prove the echo, and sets PPREV (full JSON), PST (.status), PH
# (.plan_hash, "" when null), PR (.resource, "" when null), PRC (exit: 0 iff ok/no_op).
plan_run() { # verb [pkgs...]
    REQ_VERB=$1; shift
    REQ_PKGS_STR="$*"
    REQ_PKGS_JSON=$(jq -cn '$ARGS.positional' --args "$@")
    rec_schema "$REQ_VERB"
    PPREV=$(jq -cn --arg v "$REQ_VERB" \
                '{schema_version:1,verb:$v,packages:$ARGS.positional}' --args "$@" \
            | sudo -u aptbot runix-apt-preview 2>/dev/null)
    PRC=$?
    PST=$(jq -r '.status // ""' <<<"$PPREV" 2>/dev/null)
    PH=$(jq -r '.plan_hash // ""' <<<"$PPREV" 2>/dev/null)
    PR=$(jq -r '.resource // ""' <<<"$PPREV" 2>/dev/null)
}
# plan_guard: strictly validate the fetched response and HARD-STOP the whole run if it
# is invalid: a malformed production planner voids the parity proof, so the script
# exits BEFORE any gate can hand a bogus hash to rab-exercise (do NOT weaken this to a
# per-gate check; several gates call do_ex unconditionally). Valid previews emit a
# strict-valid gate and continue.
plan_guard() {
    pvalidate
    local lbl="preview[$REQ_VERB${REQ_PKGS_STR:+ $REQ_PKGS_STR}]"
    if [ "$PVALID" = 1 ]; then
        ok "$lbl strict-valid ($PST)"
    else
        no "$lbl INVALID -> hard-stop" "$PVMSG"
        exit 1
    fi
}
# do_plan: fetch + strictly validate. On an invalid response it never returns (the run
# aborts), so no caller can proceed to redeem an unvalidated hash. The usable-plan test
# the gates then use stays `PRC==0 && -n PH` (ok carries a hash; no_op does not).
do_plan() { plan_run "$@"; plan_guard; }
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
do_issue() { # <verb> <resource> <hash> [pkgs...] -> EX* via the REAL pkgops path
    # apt-issue (aptbot) recomputes the preview through apt_<verb>_preview(), compares
    # the passed resource/hash byte-for-byte, then commits through apt_<verb>(). It
    # prints ONE RESULT line in the same grammar rab-exercise uses and mirrors its exit
    # codes (0 persisted, 1 pre-intent, 3 left-open), so every gate assertion below is
    # unchanged. No socket arg: pkgops uses its default /run/runix-audit.sock.
    local out line
    out=$(sudo -u aptbot apt-issue "$@" 2>/dev/null)
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
    done < <(LC_ALL=C apt list --upgradable 2>/dev/null | awk -F/ 'NR>1 {print $1}')
}
unpin_others() { sudo rm -f "$PIN"; }
# G-INT interruption primitives. The privileged committer is located by scanning
# /proc/<pid>/exe directly (NOT pgrep -f: the pkexec client shares the cmdline but
# its exe is /usr/bin/pkexec, so a cmdline match would falsely include it). Its whole
# descendant tree is captured as (pid,starttime) identities before killing, killed
# deepest-first by identity (robust to a reparented dpkg/postinst), then every
# captured identity is verified gone.
starttime() { # field 22 of /proc/<pid>/stat, robust to spaces/parens in comm
    local s
    s=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    s=${s##*') '}
    [ -n "$s" ] && awk '{print $20}' <<<"$s"
}
find_root_helpers() { # root-owned pids whose exe IS the install entrypoint
    local d pid u exe
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        u=$(awk '/^Uid:/{print $2; exit}' "$d/status" 2>/dev/null) || continue
        [ "$u" = 0 ] || continue
        exe=$(sudo readlink -f "$d/exe" 2>/dev/null) || continue
        [ "$exe" = "$LIBX/runix-apt-install" ] && echo "$pid"
    done
}
collect_tree() { # append (pid,starttime) for pid and every descendant (pre-order)
    local pid=$1 st kid
    st=$(starttime "$pid") || return 0
    [ -n "$st" ] || return 0
    CAPPIDS+=("$pid"); CAPSTART+=("$st")
    for kid in $(pgrep -P "$pid" 2>/dev/null); do collect_tree "$kid"; done
}
all_gone() { # true iff no captured identity is still alive (same pid AND starttime)
    local i now
    for i in "${!CAPPIDS[@]}"; do
        now=$(starttime "${CAPPIDS[$i]}")
        [ -n "$now" ] && [ "$now" = "${CAPSTART[$i]}" ] && return 1
    done
    return 0
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

echo "########## G-NEG: a malformed preview hard-stops before the issuer (issuer-side) ##########"
# Prove the strict validator is a REAL gate, not advisory: an invalid planner response
# must hard-stop do_plan so the issuer is NEVER invoked. Each case injects a crafted
# response and runs the SAME plan_guard the real gates use, in a subshell with a
# tripwire do_issue; an invalid case must exit nonzero with the tripwire untouched, and
# a valid control must proceed and fire it.
neg_hardstop() { # name PPREV PH PRC expect(stop=1|proceed=0)
    local name=$1 pv=$2 ph=$3 rc=$4 expect=$5 TRIP; TRIP=$(mktemp -u)
    ( do_issue() { : >"$TRIP"; }                 # tripwire: fires iff the issuer runs
      PPREV=$pv; PST=$(jq -r '.status // ""' <<<"$pv" 2>/dev/null); PH=$ph; PRC=$rc
      REQ_VERB=apt.install; REQ_PKGS_STR=x; REQ_PKGS_JSON='["x"]'; rec_schema apt.install
      plan_guard                                 # exits 1 iff invalid
      do_issue apt.install x "$ph" x ) >/dev/null 2>&1
    local rc2=$?
    if [ "$expect" = 1 ]; then
        { [ "$rc2" -ne 0 ] && [ ! -e "$TRIP" ]; } \
            && ok "G-NEG $name hard-stopped, issuer not invoked" \
            || no "G-NEG $name" "rc=$rc2 trip=$([ -e "$TRIP" ] && echo FIRED || echo clean)"
    else
        { [ "$rc2" -eq 0 ] && [ -e "$TRIP" ]; } \
            && ok "G-NEG $name valid -> proceeds to the issuer" \
            || no "G-NEG $name" "rc=$rc2 trip=$([ -e "$TRIP" ] && echo fired || echo MISSING)"
    fi
    rm -f "$TRIP"
}
NEGH=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
NEGTXN='[{"package":"x","architecture":"amd64","action":"install","from_version":"","to_version":"1.0","flags":[]}]'
neg_hardstop "ok-no-digest"     '{"schema_version":1,"status":"ok","verb":"apt.install","packages":["x"],"plan_schema":null,"resource":"x","plan_hash":null,"records":[],"detail":null}' "" 0 1
neg_hardstop "noop-with-digest" "{\"schema_version\":1,\"status\":\"no_op\",\"verb\":\"apt.install\",\"packages\":[\"x\"],\"plan_schema\":1,\"resource\":\"x\",\"plan_hash\":\"$NEGH\",\"records\":$NEGTXN,\"detail\":null}" "$NEGH" 0 1
neg_hardstop "verb-mismatch"    '{"schema_version":1,"status":"no_op","verb":"apt.remove","packages":["x"],"plan_schema":null,"resource":"x","plan_hash":null,"records":[],"detail":null}' "" 0 1
neg_hardstop "missing-key"      '{"schema_version":1,"status":"no_op","verb":"apt.install","packages":["x"],"plan_schema":null,"resource":"x","plan_hash":null,"records":[]}' "" 0 1
neg_hardstop "bad-record"       "{\"schema_version\":1,\"status\":\"ok\",\"verb\":\"apt.install\",\"packages\":[\"x\"],\"plan_schema\":1,\"resource\":\"x\",\"plan_hash\":\"$NEGH\",\"records\":[{\"uri\":\"u\",\"suite\":\"s\",\"components\":[],\"options\":{}}],\"detail\":null}" "$NEGH" 0 1
neg_hardstop "exit-mismatch"    "{\"schema_version\":1,\"status\":\"ok\",\"verb\":\"apt.install\",\"packages\":[\"x\"],\"plan_schema\":1,\"resource\":\"x\",\"plan_hash\":\"$NEGH\",\"records\":$NEGTXN,\"detail\":null}" "$NEGH" 1 1
neg_hardstop "valid-control"    "{\"schema_version\":1,\"status\":\"ok\",\"verb\":\"apt.install\",\"packages\":[\"x\"],\"plan_schema\":1,\"resource\":\"x\",\"plan_hash\":\"$NEGH\",\"records\":$NEGTXN,\"detail\":null}" "$NEGH" 0 0

echo "########## G1: update good-source -> applied, durable audit ##########"
do_plan apt.update
if [ "$PRC" = 0 ] && [ -n "$PH" ]; then
    do_issue apt.update "" "$PH"
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
do_issue apt.update "" "$PH"
{ [ "$EXSTATUS" = operation_failed ] && [ "$EXEFFECT" = true ]; } \
    && ok "G2 bad-source -> operation_failed" || no "G2" "status=$EXSTATUS eff=$EXEFFECT"
sudo rm -f "$BROKENSRC"

echo "########## G3: benign install (temp-grant) -> applied ##########"
grant install
sudo apt-get remove -y canary-benign >/dev/null 2>&1 || true
do_plan apt.install canary-benign
do_issue apt.install "$PR" "$PH" canary-benign
{ [ "$EXSTATUS" = ok ] && [ "$EXEFFECT" = true ]; } \
    && ok "G3 install status ok" || no "G3 install" "status=$EXSTATUS eff=$EXEFFECT"
dpkg_state canary-benign | grep -q "install ok installed" \
    && ok "G3 canary-benign installed (native)" || no "G3 dpkg" "$(dpkg_state canary-benign)"
audit_intent_outcome "$EXCID" "G3"
ungrant

echo "########## G4: benign remove (temp-grant) -> applied ##########"
grant remove
do_plan apt.remove canary-benign
do_issue apt.remove "$PR" "$PH" canary-benign
{ [ "$EXSTATUS" = ok ] && [ "$EXEFFECT" = true ]; } \
    && ok "G4 remove status ok" || no "G4 remove" "status=$EXSTATUS eff=$EXEFFECT"
dpkg_state canary-benign | grep -q "install ok installed" \
    && no "G4 dpkg" "still installed" || ok "G4 canary-benign removed (native)"
ungrant

echo "########## G5: whole-system upgrade (temp-grant) 1.0 -> 1.1 ##########"
grant upgrade
# Setup + PROVE it BEFORE planning: a silently failed fixture install surfaces here
# (as the precondition), not later as an unexplained empty post-upgrade version.
sudo apt-get install -y --allow-downgrades canary-benign=1.0 >/dev/null 2>&1
SETUP_OK=0; [ "$(dpkg_ver canary-benign)" = 1.0 ] && SETUP_OK=1
[ "$SETUP_OK" -eq 1 ] && ok "G5 setup: canary-benign == 1.0 before upgrade" \
    || no "G5 setup" "ver=$(dpkg_ver canary-benign) (expected 1.0)"
# Isolate the whole-system upgrade to the canary transition: pin every OTHER
# upgradable package to its installed version (removed below and in the trap).
pin_others
# The SIMULATED whole-system upgrade (same FORBID_REMOVE semantics as the effector's
# apt.upgrade, parsed under LC_ALL=C) must be EXACTLY canary-benign 1.0->1.1, nothing else.
SIM=$(LC_ALL=C apt-get -s upgrade --with-new-pkgs 2>/dev/null | grep -E '^(Inst|Remv|Purg) ')
CBLINE=$(grep -E '^Inst canary-benign \[1\.0\] \(1\.1' <<<"$SIM")
OTHER=$(grep -vE '^Inst canary-benign ' <<<"$SIM" | grep -E '^(Inst|Remv|Purg) ')
SIM_OK=0; { [ -n "$CBLINE" ] && [ -z "$OTHER" ]; } && SIM_OK=1
[ "$SIM_OK" -eq 1 ] && ok "G5 plan: only canary-benign 1.0->1.1, no unrelated changes" \
    || no "G5 plan" "cb='$CBLINE' other='$(tr '\n' ';' <<<"$OTHER")'"
# Run the REAL upgrade ONLY when isolation is proven, so a failed precondition or
# simulation can never trigger the base image's unrelated upgrades. Require a clean
# plan (PRC==0, nonempty hash) before issuing the receipt.
if [ "$SETUP_OK" -eq 1 ] && [ "$SIM_OK" -eq 1 ]; then
    do_plan apt.upgrade
    if [ "${PRC:-1}" -eq 0 ] && [ -n "${PH:-}" ]; then
        do_issue apt.upgrade "$PR" "$PH"
        { [ "$EXSTATUS" = ok ] && [ "$EXEFFECT" = true ]; } \
            && ok "G5 upgrade status ok" || no "G5 upgrade" "status=$EXSTATUS eff=$EXEFFECT"
        [ "$(dpkg_ver canary-benign)" = 1.1 ] \
            && ok "G5 canary-benign upgraded to 1.1 (native)" || no "G5 dpkg" "ver=$(dpkg_ver canary-benign)"
    else
        no "G5 plan-hash" "PRC=${PRC:-?} hash='${PH:-}' (no receipt issued)"
    fi
else
    no "G5 upgrade" "isolation not proven (setup=$SETUP_OK sim=$SIM_OK); real upgrade skipped"
fi
unpin_others
[ -e "$PIN" ] && no "G5 pins" "pin file survived removal" || ok "G5 pins removed + verified"
ungrant

echo "########## G8: hold (autonomous) then unhold (temp-grant), selection read-back ##########"
sudo apt-get install -y canary-benign >/dev/null 2>&1
do_plan apt.hold canary-benign
do_issue apt.hold "$PR" "$PH" canary-benign
sel=$(dpkg_state canary-benign | awk '{print $1}')
{ [ "$EXSTATUS" = ok ] && [ "$sel" = hold ]; } \
    && ok "G8 hold applied, selection=$sel" || no "G8 hold" "status=$EXSTATUS sel=$sel"
grant unhold  # unhold is NOT autonomous
do_plan apt.unhold canary-benign
do_issue apt.unhold "$PR" "$PH" canary-benign
sel=$(dpkg_state canary-benign | awk '{print $1}')
{ [ "$EXSTATUS" = ok ] && [ "$sel" = install ]; } \
    && ok "G8 unhold applied, selection=$sel" || no "G8 unhold" "status=$EXSTATUS sel=$sel"
ungrant

echo "########## G9: protected removal refused (preview-side, no intent) ##########"
# Through pkgops the protected refusal is PREVIEW-side: apt_remove_preview() raises
# protected_package, so no intent opens and no receipt is spent (effect_issued=false).
grant remove
do_issue apt.remove canary-protected "$ZERO" canary-protected
{ [ "$EXSTATUS" = protected_package ] && [ "$EXEFFECT" = false ]; } \
    && ok "G9 protected removal refused" || no "G9" "status=$EXSTATUS eff=$EXEFFECT"
dpkg_state canary-protected | grep -q "install ok installed" \
    && ok "G9 canary-protected still installed" || no "G9 dpkg" "$(dpkg_state canary-protected)"
ungrant

echo "########## G-OWN: rapt-owned package refused (ownership, autonomous hold) ##########"
# r-cornball-canary matches ^r-[a-z]+-[a-z0-9.]+$ -> package_not_owned. Through pkgops
# this is a PREVIEW-side refusal: apt_hold_preview() itself raises, so NO intent is
# opened (effect_issued=false) and the placeholder hash is never reached. hold is
# autonomous, so no grant is needed.
do_issue apt.hold r-cornball-canary "$ZERO" r-cornball-canary
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
do_issue apt.update "" "$PH"
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

# G12-G14 stay on rab-exercise (the broker/receipt oracle), NOT the pkgops issuer:
# each deliberately presents a bad/replayed/stale RECEIPT at the redeem boundary, which
# the pkgops path structurally cannot do -- apt-issue recomputes and commits only the
# preview it derived itself, minting its own receipt, so it can never hand the broker a
# wrong/replayed/drifted hash. These prove the broker's receipt defense BELOW the issuer.
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
# Stays on rab-exercise (the native oracle): this injects a package into a NULLARY
# entrypoint to prove its arity defense (update's arity is 0 -> internal). The pkgops
# API cannot express it -- apt_update() has no package parameter -- so the injection
# only reaches the entrypoint through the oracle, not the issuer.
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
# The pkgops launcher (an Rscript, the aptbot ANCESTOR of the pkexec-spawned root
# committer) is deliberately NOT in the kill set: only the root helper subtree is
# killed, so apt-issue survives to catch the commit's failure and record the intent
# LEFT OPEN. pkgops now attaches the session cid to that left-open condition, so the
# RESULT line still carries the cid the receipt-state assertion needs.
sudo -u aptbot apt-issue apt.install "$PR" "$PH" canary-slow >"$INTOUT" 2>&1 &
BGPID=$!
# Synchronize on the postinst marker: it appears only AFTER redeem + unpack, while
# the configure (postinst) is mid-run — the real post-redeem interruption window.
MARKED=0
for _ in $(seq 1 120); do [ -e /run/canary-slow.marker ] && { MARKED=1; break; }; sleep 0.5; done
# The pkexec-spawned committer is reparented under polkitd, NOT a child of the pkexec
# client (killing the client leaves dpkg running to completion). Do not touch anything
# until the postinst marker exists AND exactly one root-owned process whose
# /proc/<pid>/exe IS the entrypoint is identified. Capture its complete descendant tree
# as (pid,starttime) identities, kill deepest-first by identity (so a reparented
# dpkg/postinst is still killed), and require EVERY captured identity gone, not just the
# helper. On any sync/identity failure, fail without pretending an interruption occurred:
# do not kill, and let the honest outcome assertions below register it.
mapfile -t HELPERS < <(find_root_helpers)
CAPPIDS=(); CAPSTART=()
if [ "$MARKED" -eq 1 ] && [ "${#HELPERS[@]}" -eq 1 ]; then
    ok "G-INT one root helper located (pid ${HELPERS[0]})"
    collect_tree "${HELPERS[0]}"
    if [ "${#CAPPIDS[@]}" -ge 2 ]; then
        ok "G-INT captured transaction tree (${#CAPPIDS[@]} procs: helper + dpkg/postinst)"
        # Kill the captured identities deepest-first (reverse of pre-order capture),
        # each re-verified by (pid,starttime) so a reused pid is never killed.
        for (( i=${#CAPPIDS[@]}-1; i>=0; i-- )); do
            [ "$(starttime "${CAPPIDS[$i]}")" = "${CAPSTART[$i]}" ] \
                && sudo kill -9 "${CAPPIDS[$i]}" 2>/dev/null
        done
        SUBGONE=0
        for _ in $(seq 1 40); do all_gone && { SUBGONE=1; break; }; sleep 0.25; done
        [ "$SUBGONE" -eq 1 ] \
            && ok "G-INT whole captured tree gone (no reparented dpkg/postinst survived)" \
            || no "G-INT subtree" "a captured (pid,starttime) survived the kill"
    else
        no "G-INT capture" "captured ${#CAPPIDS[@]} procs (expected helper + dpkg/postinst)"
    fi
else
    no "G-INT locate" "marked=$MARKED root-helpers=${#HELPERS[@]} (need marker + exactly 1); not killing"
fi
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
do_issue apt.install "$PR" "$PH" canary-badpost
{ [ "$EXSTATUS" = dpkg_broken ] && [ "$EXEFFECT" = true ]; } \
    && ok "G6 failed-postinst -> dpkg_broken (effect issued)" || no "G6" "status=$EXSTATUS eff=$EXEFFECT"
dpkg_state canary-badpost | grep -q "half-configured" \
    && ok "G6 canary-badpost half-configured (State != NeedsNothing)" || no "G6 dpkg" "$(dpkg_state canary-badpost)"
ungrant
grant configure
do_plan apt.configure
do_issue apt.configure "$PR" "$PH"
{ [ "$EXSTATUS" = dpkg_broken ] && [ "$EXEFFECT" = true ]; } \
    && ok "G7 configure of a still-failing package -> dpkg_broken" || no "G7" "status=$EXSTATUS eff=$EXEFFECT"
ungrant
echo "  [cleanup] removing the deliberately-broken canary-badpost"
sudo dpkg --remove --force-remove-reinstreq canary-badpost >/dev/null 2>&1 || true
sudo dpkg --purge canary-badpost >/dev/null 2>&1 || true

echo "########## G-INLINE: apt.update over an inline-Signed-By source -> inline-sha256, redeems ##########"
# The signed inline-key repo is staged out of sources.list.d by the fixtures; add it
# only for this gate (like the drift source), so the other update gates keep their
# hash. apt.update must fetch AND verify it (signed), the preview must show the key
# as inline-sha256:<hex> and never leak armor, and that exact hash must redeem.
sudo cp /srv/canary-inline.sources "$INLINESRC"
sudo apt-get update -qq
do_plan apt.update
ISB=$(jq -r '.records[]|select(.uri|test("canary-signed"))|.options."signed-by" // empty' <<<"$PPREV")
[[ "$ISB" =~ ^inline-sha256:[0-9a-f]{64}$ ]] \
    && ok "G-INLINE preview record signed-by=$ISB" \
    || no "G-INLINE inline-sha256" "signed-by='$ISB'"
grep -q "BEGIN PGP" <<<"$PPREV" \
    && no "G-INLINE armor leak" "armored key material in preview stdout" \
    || ok "G-INLINE no armored key material in preview output"
if [ "$PVALID" = 1 ] && [ "$PRC" = 0 ] && [ -n "$PH" ]; then
    do_issue apt.update "" "$PH"
    { [ "$EXSTATUS" = ok ] && [ "$EXEFFECT" = true ]; } \
        && ok "G-INLINE preview hash redeems through the locked update effector" \
        || no "G-INLINE redeem" "status=$EXSTATUS eff=$EXEFFECT"
else
    no "G-INLINE plan" "valid=$PVALID PRC=$PRC hash='${PH:0:12}' (no receipt issued)"
fi
sudo rm -f "$INLINESRC"
sudo apt-get update -qq

echo "########## G-PREV-OWN: preview refuses rapt-owned (package_not_owned), opens NO intent ##########"
# The FUTURE issuer's behavior: a preview refusal stops before open_intent. Prove it
# natively — runix-apt-preview as aptbot refuses, we never call rab-exercise, and the
# audit sink is byte-identical across the preview (no intent, no record). This is
# additive to G-OWN, which still proves the privileged boundary's own defense.
SB0=$(sudo sha256sum "$SINK" 2>/dev/null | cut -d' ' -f1)
do_plan apt.hold r-cornball-canary
SB1=$(sudo sha256sum "$SINK" 2>/dev/null | cut -d' ' -f1)
POWN=$(jq -e '.status=="package_not_owned" and .verb=="apt.hold"
    and .packages==["r-cornball-canary"] and .plan_schema==1
    and .resource=="r-cornball-canary" and (.plan_hash|test("^[0-9a-f]{64}$"))
    and (.records|length)>0 and .detail=="r-cornball-canary"' <<<"$PPREV" >/dev/null \
    && echo 1 || echo 0)
{ [ "$POWN" = 1 ] && [ "$PST" = package_not_owned ] && [ "$PRC" -ne 0 ]; } \
    && ok "G-PREV-OWN strict package_not_owned + nonzero exit (no rab-exercise)" \
    || no "G-PREV-OWN response" "status=$PST rc=$PRC strict=$POWN"
{ [ -n "$SB0" ] && [ "$SB0" = "$SB1" ]; } \
    && ok "G-PREV-OWN audit sink byte-identical (no intent opened)" \
    || no "G-PREV-OWN sink" "sink '$SB0' -> '$SB1'"

echo "########## G-PREV-NOOP: preview no_op (already satisfied), opens NO intent ##########"
# canary-protected is installed at its only version -> an empty transaction -> no_op,
# distinct from a refusal. The issuer opens no intent; prove the sink is untouched.
SB0=$(sudo sha256sum "$SINK" 2>/dev/null | cut -d' ' -f1)
do_plan apt.install canary-protected
SB1=$(sudo sha256sum "$SINK" 2>/dev/null | cut -d' ' -f1)
PNOOP=$(jq -e '.status=="no_op" and .verb=="apt.install"
    and .packages==["canary-protected"] and .plan_schema==null and .plan_hash==null
    and (.records|length)==0 and .resource=="canary-protected" and .detail==null' <<<"$PPREV" >/dev/null \
    && echo 1 || echo 0)
{ [ "$PNOOP" = 1 ] && [ "$PST" = no_op ] && [ "$PRC" -eq 0 ]; } \
    && ok "G-PREV-NOOP strict no_op + exit 0 (no rab-exercise)" \
    || no "G-PREV-NOOP response" "status=$PST rc=$PRC strict=$PNOOP"
{ [ -n "$SB0" ] && [ "$SB0" = "$SB1" ]; } \
    && ok "G-PREV-NOOP audit sink byte-identical (no intent opened)" \
    || no "G-PREV-NOOP sink" "sink '$SB0' -> '$SB1'"

echo
echo "==== §7 apt-mutation gates: $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
