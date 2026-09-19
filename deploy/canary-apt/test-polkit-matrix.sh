#!/bin/bash
# Exercise the actual matrix under a controlling PTY. All privilege/auth tools
# are fakes; timeout is real but runs as this user. No host policy is touched.
set -euo pipefail
HERE=$(dirname "$(readlink -f "$0")")
MATRIX_TEST=$(mktemp -d)
export MATRIX_TEST
trap 'rc=$?; if [ "$rc" -ne 0 ]; then cat "$MATRIX_TEST/output" >&2; fi; rm -rf "$MATRIX_TEST"; exit "$rc"' EXIT
mkdir "$MATRIX_TEST/bin"
cat > "$MATRIX_TEST/bin/sudo" <<'EOF'
#!/bin/bash
# Require the actual supervisor/privilege order, independent of matrix helpers.
[ "$1" = -n ] && [ "$2" = timeout ] && [ "$3" = --kill-after=2s ] &&
    [ "$4" = 15s ] && [ "$5" = runuser ] || exit 98
[ "$MATRIX_MODE" != sudo_fail ] || exit 1
shift
exec "$@"
EOF
cat > "$MATRIX_TEST/bin/timeout" <<'EOF'
#!/bin/bash
[ "$1" = --kill-after=2s ] && [ "$2" = 15s ] || exit 98
shift 2
# Shorten only the negative control; preserve real process-group supervision.
exec /usr/bin/timeout --kill-after=0.2s 2s "$@"
EOF
cat > "$MATRIX_TEST/bin/runuser" <<'EOF'
#!/bin/bash
[ "$1" = -u ] && [ "$3" = -- ] || exit 98
export MATRIX_PRINCIPAL=$2
shift 3
exec "$@"
EOF
cat > "$MATRIX_TEST/bin/pkcheck" <<'EOF'
#!/bin/bash
[ "$#" -eq 4 ] && [ "$1" = --action-id ] && [ "$3" = --process ] || exit 99
[[ "$4" =~ ^[0-9]+,[0-9]+,[0-9]+$ ]] || exit 99
# A readable controlling terminal exists even though stdin is /dev/null.
(: </dev/tty) 2>/dev/null || exit 99
echo yes > "$MATRIX_TEST/tty-seen"
if [ "$MATRIX_PRINCIPAL" = aptbot ]; then
    case "$2" in *.update|*.hold) exit 0;; esac
fi
echo 'synthetic policy challenge' >&2
exit 2
EOF
cat > "$MATRIX_TEST/bin/Rscript" <<'EOF'
#!/bin/bash
[ "$#" -eq 2 ] && [ "$1" = --vanilla ] && [ -r "$2" ] || exit 98
(: </dev/tty) 2>/dev/null || exit 99
echo yes > "$MATRIX_TEST/api-seen"
case "$MATRIX_MODE" in
    hang)
        trap '' TERM
        echo "$$" > "$MATRIX_TEST/hung-pid"
        while :; do sleep 1; done ;;
    bad_reply) echo 'unexpected authorization'; exit 0 ;;
    probe_fail) exit 1 ;;
esac
echo 'MACHINE_REFUSAL cid=synthetic-p4 status=approval_required effect_issued=false effect_session_opened=false'
EOF
cat > "$MATRIX_TEST/bin/pkexec" <<'EOF'
#!/bin/bash
echo 'UNSAFE: raw pkexec reached' > "$MATRIX_TEST/pkexec-ran"
exit 127
EOF
chmod +x "$MATRIX_TEST/bin/"*
export MATRIX_SCRIPT="$HERE/polkit-matrix.sh"
for mode in good sudo_fail bad_reply probe_fail hang; do
    rm -f "$MATRIX_TEST/tty-seen" "$MATRIX_TEST/api-seen"
    # P5 inspects real paths read-only and can fail on a workstation without
    # pkgexec. We assess only P1-P4 here; no fabricated P5 pass is counted.
    env PATH="$MATRIX_TEST/bin:$PATH" MATRIX_MODE="$mode" \
        script -q -e -c 'bash "$MATRIX_SCRIPT"' /dev/null \
        > "$MATRIX_TEST/output" 2>&1 </dev/null || true
    [ ! -e "$MATRIX_TEST/pkexec-ran" ]
    if [ "$mode" = sudo_fail ]; then
        [ ! -e "$MATRIX_TEST/tty-seen" ] && [ ! -e "$MATRIX_TEST/api-seen" ]
        ! grep -Eq 'PASS  P[1-4]' "$MATRIX_TEST/output"
    else
        [ -e "$MATRIX_TEST/tty-seen" ] && [ -e "$MATRIX_TEST/api-seen" ]
        [ "$(grep -Ec 'PASS  P[1-3]|PASS  P4 pkcheck' "$MATRIX_TEST/output")" -eq 12 ]
        if [ "$mode" = good ]; then
            grep -Fq 'PASS  P4 pkgops machine-mode refused before effect-session open' "$MATRIX_TEST/output"
        else
            grep -Fq 'FAIL  P4 pkgops machine-mode' "$MATRIX_TEST/output"
            ! grep -Fq 'PASS  P4 pkgops' "$MATRIX_TEST/output"
        fi
    fi
    if [ "$mode" = hang ]; then
        pid=$(cat "$MATRIX_TEST/hung-pid")
        ! kill -0 "$pid" 2>/dev/null
    fi
    echo "PASS terminal matrix: $mode"
done
echo '5 terminal-matrix checks passed (privilege and policy tools stubbed)'
