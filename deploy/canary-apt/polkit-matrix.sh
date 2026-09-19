#!/bin/bash
# Polkit authorization matrix on the disposable target. Run as the ordinary
# operator with an existing sudo credential. P4 uses the real pkgops machine-mode
# refusal and broker audit, with a tripwire before effect-session open. No effect
# receipt or privileged effector is used. Decisions query the principal with the full
# `pid,start-time,uid` subject (race-safe), so the rule sees the principal's real
# uid and group membership.
set -uo pipefail
HERE=$(dirname "$(readlink -f "$0")")
ACT=ai.cornball.runix.apt
LIBX=/usr/libexec/pkgexec
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
no() { echo "  FAIL  $1 ($2)"; fail=$((fail + 1)); }

# A tiny helper that pkchecks its OWN process with the full pid,start-time,uid
# subject. start-time is read past the "comm)" field so a comm with spaces cannot
# shift it. Emit a tagged result so sudo/runuser failures cannot masquerade as a
# policy denial. pkcheck: 0 authorized, 1 denied, 2 unavailable, 3 dismissed.
PKQ="$(mktemp)"
REFUSAL="$(mktemp)"
trap 'rm -f "$PKQ" "$REFUSAL"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
cp "$HERE/machine-refusal.R" "$REFUSAL" || exit 1
chmod 0644 "$REFUSAL"
cat > "$PKQ" <<'EOF'
#!/bin/bash
stat=$(cat /proc/$$/stat); rest=${stat##*') '}; start=$(echo "$rest" | cut -d" " -f20)
pkcheck --action-id "$1" --process "$$,$start,$(id -u)" >/dev/null 2>&1
printf 'PKCHECK=%s\n' "$?"
EOF
chmod 0755 "$PKQ"
# The supervisor must have permission to signal ALL descendants. An unprivileged
# timeout outside sudo cannot reliably stop a privileged child. Escalate to KILL
# if TERM is ignored; never request a password from this test.
as_principal() {
    local principal=$1
    shift
    sudo -n timeout --kill-after=2s 15s runuser -u "$principal" -- "$@" </dev/null
}
authz() {
    local reply rc
    reply=$(as_principal "$1" "$PKQ" "$2" 2>&1); rc=$?
    [ "$rc" -eq 0 ] || return 99
    case "$reply" in
        PKCHECK=0) return 0 ;; PKCHECK=1) return 1 ;;
        PKCHECK=2) return 2 ;; PKCHECK=3) return 3 ;;
        *) return 99 ;;
    esac
}

expect_allow() { # user action label
    authz "$1" "$2"; local rc=$?
    [ "$rc" -eq 0 ] && ok "$3 allowed (rc=0)" || no "$3" "rc=$rc, expected authorized"
}
expect_deny() { # user action label
    # A machine-mode refusal is rc 1 (denied) or rc 2 (authorization unavailable:
    # no agent / interaction disabled). rc 3 (an interaction was dismissed), rc
    # 126/127, and a timeout are FAILURES, not valid prompt-free refusals.
    authz "$1" "$2"; local rc=$?
    case "$rc" in
        1 | 2) ok "$3 refused prompt-free (rc=$rc)" ;;
        0) no "$3" "authorized (rc=0)" ;;
        3) no "$3" "interaction dismissed (rc=3)" ;;
        *) no "$3" "tooling failure rc=$rc" ;;
    esac
}

echo "## PROOF 1: non-member (aptuser) denied the autonomous verbs"
expect_deny aptuser "$ACT.update" "P1 aptuser update"
expect_deny aptuser "$ACT.hold"   "P1 aptuser hold"

echo "## PROOF 2: enrolled member (aptbot) allowed ONLY update + hold (machine mode)"
expect_allow aptbot "$ACT.update" "P2 aptbot update"
expect_allow aptbot "$ACT.hold"   "P2 aptbot hold"

echo "## PROOF 3: enrolled member STILL denied unhold + every package-changing verb"
for act in unhold install remove purge upgrade dist_upgrade configure; do
    expect_deny aptbot "$ACT.$act" "P3 aptbot $act"
done

echo "## PROOF 4: machine mode never prompts (a timeout is a FAILURE, not a denial)"
expect_deny aptbot "$ACT.install" "P4 pkcheck gated"
reply=$(as_principal aptbot Rscript --vanilla "$REFUSAL" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [[ "$reply" =~ ^MACHINE_REFUSAL\ cid=[A-Za-z0-9_-]+\ status=(unauthorized|approval_required)\ effect_issued=false\ effect_session_opened=false$ ]]; then
    echo "$reply"
    ok "P4 pkgops machine-mode refused before effect-session open"
else
    no "P4 pkgops machine-mode" "probe failed or exceeded deadline (rc=$rc)"
fi

echo "## PROOF 5: nine entrypoints — regular non-symlink files, root-owned, unwritable, distinct inodes"
declare -A seen
for v in install remove purge upgrade dist-upgrade update hold unhold configure; do
    p="$LIBX/runix-apt-$v"
    if [ ! -f "$p" ] || [ -L "$p" ]; then
        no "P5 $v" "not a regular file"
        continue
    fi
    read -r owner group mode < <(stat -c '%U %G %a' "$p")
    ino=$(stat -c '%i' "$p")
    wbits=$((8#$mode & 8#22))
    if [ "$owner" = root ] && [ "$wbits" -eq 0 ] && [ -z "${seen[$ino]:-}" ]; then
        ok "P5 $v ($owner:$group $mode, inode $ino)"
        seen[$ino]=1
    else
        no "P5 $v" "$owner:$group $mode inode=$ino dup=${seen[$ino]:-no}"
    fi
done
[ "${#seen[@]}" -eq 9 ] && ok "P5 nine distinct inodes" || no "P5 inodes" "${#seen[@]} distinct"

echo
echo "==== polkit matrix: $pass passed, $fail failed ===="
[ "$fail" -eq 0 ]
