#!/bin/bash
# Polkit authorization matrix (codex's five proofs) inside the guest. Run as
# `ubuntu`. Receipt-INDEPENDENT: this decides authorization at/before the pkexec
# boundary (pkcheck decisions + filesystem modes), so no broker, no receipt, and no
# commit are involved. Decisions query the PRINCIPAL's own process with the FULL
# `pid,start-time,uid` subject (race-safe), so the rule sees the principal's real
# uid and group membership.
set -uo pipefail
ACT=ai.cornball.runix.apt
LIBX=/usr/libexec/pkgexec
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
no() { echo "  FAIL  $1 ($2)"; fail=$((fail + 1)); }

# A tiny helper that pkchecks its OWN process with the full pid,start-time,uid
# subject. start-time is read past the "comm)" field so a comm with spaces cannot
# shift it. Its exit code IS pkcheck's: 0 authorized, 1 not authorized, 2 error,
# 3 authorization-required (challenge, interaction not allowed).
PKQ="$(mktemp)"
cat > "$PKQ" <<'EOF'
#!/bin/bash
stat=$(cat /proc/$$/stat); rest=${stat##*') '}; start=$(echo "$rest" | cut -d" " -f20)
pkcheck --action-id "$1" --process "$$,$start,$(id -u)"
EOF
chmod 0755 "$PKQ"
trap 'rm -f "$PKQ"' EXIT
authz() { sudo -u "$1" "$PKQ" "$2" >/dev/null 2>&1; } # returns pkcheck rc

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
timeout 15 sudo -u aptbot "$PKQ" "$ACT.install" >/dev/null 2>&1; rc=$?
case "$rc" in
    124) no "P4 pkcheck gated" "TIMEOUT (prompted/hung)" ;;
    1 | 2) ok "P4 pkcheck gated refused prompt-free (rc=$rc)" ;;
    0) no "P4 pkcheck gated" "authorized" ;;
    3) no "P4 pkcheck gated" "interaction dismissed (rc=3)" ;;
    *) no "P4 pkcheck gated" "tooling failure rc=$rc" ;;
esac
# pkexec's prompt-free refusal is observed as rc 127 (no agent / not authorized).
timeout 15 sudo -u aptbot pkexec "$LIBX/runix-apt-install" </dev/null >/dev/null 2>&1; rc=$?
case "$rc" in
    124) no "P4 pkexec gated" "TIMEOUT (prompted/hung)" ;;
    126 | 127) ok "P4 pkexec gated refused (rc=$rc), no prompt" ;;
    0) no "P4 pkexec gated" "ran a gated verb" ;;
    *) no "P4 pkexec gated" "unexpected rc=$rc" ;;
esac

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
