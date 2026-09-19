#!/bin/bash
# Local synthetic checks. No apt, polkit, broker, SSH, or privileged command runs.
set -euo pipefail
HERE=$(dirname "$(readlink -f "$0")")
TESTROOT=$(mktemp -d)
export TESTROOT
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ -f "$TESTROOT/last-output" ]; then cat "$TESTROOT/last-output" >&2; fi; rm -rf "$TESTROOT"; exit "$rc"' EXIT
pass=0
ok() { echo "PASS $*"; pass=$((pass+1)); }
expect_failure() {
    if "$@" > "$TESTROOT/last-output" 2>&1; then
        echo "unexpected success: $*" >&2; exit 1
    fi
}
mkdir "$TESTROOT/good"
jq -n -f "$HERE/test-evidence-fixture.jq" > "$TESTROOT/fixture.json"
jq -c '.audit[]' "$TESTROOT/fixture.json" > "$TESTROOT/good/audit-redacted.jsonl"
jq -c '.audit[] | if .record_type == "broker_receipt" then .state=.receipt_state | del(.receipt_state) else . end' \
    "$TESTROOT/fixture.json" > "$TESTROOT/audit-raw.jsonl"
printf '==== polkit matrix: 23 passed, 0 failed ====\n' > "$TESTROOT/good/03-matrix.log"
cp "$TESTROOT/good/03-matrix.log" "$TESTROOT/good/05-matrix-after.log"
{
    jq -r '.calls[] | "EVIDENCE " + tojson' "$TESTROOT/fixture.json"
    for g in G11a G11b G-NEG G-PREV-OWN G-PREV-NOOP; do echo "  PASS  $g fixture"; done
    echo '==== §7 apt-mutation gates: 70 passed, 0 failed ===='
} > "$TESTROOT/good/04-gates.log"
bash "$HERE/verify-evidence.sh" "$TESTROOT/good" >/dev/null
ok 'valid synthetic evidence accepted'

bad_audit() {
    local label=$1 filter=$2
    cp -r "$TESTROOT/good" "$TESTROOT/bad"
    jq -c "$filter" "$TESTROOT/good/audit-redacted.jsonl" > "$TESTROOT/bad/audit-redacted.jsonl"
    expect_failure bash "$HERE/verify-evidence.sh" "$TESTROOT/bad"
    rm -r "$TESTROOT/bad"
    ok "$label rejected"
}
bad_audit 'missing durable outcome' 'select(.correlation_id != "fixture-G3" or .phase != "outcome")'
bad_audit 'wrong actor' 'if .correlation_id=="fixture-G3" and .phase=="outcome" then .actor="uid:0" else . end'
bad_audit 'wrong post-state' 'if .correlation_id=="fixture-G3" and .phase=="outcome" then .observed["canary-benign:all"].version="9" else . end'
bad_audit 'false effect report' 'if .correlation_id=="fixture-G3" and .phase=="outcome" then .effect_issued=false else . end'
bad_audit 'fabricated update transition' 'if .correlation_id=="fixture-G1" and .phase=="outcome" then .state_changed=true else . end'
bad_audit 'unredeemed interruption' 'if .correlation_id=="fixture-G-INT" and .record_type=="broker_receipt" then .receipt_state="issued" else . end'
bad_audit 'secret in projection' '. + {binding:"synthetic-secret"}'
bad_audit 'empty audit' 'empty'
cp -r "$TESTROOT/good" "$TESTROOT/bad"
printf 'EVIDENCE {broken-json\n' >> "$TESTROOT/bad/04-gates.log"
expect_failure bash "$HERE/verify-evidence.sh" "$TESTROOT/bad"
rm -r "$TESTROOT/bad"
ok 'corrupt gate result rejected'

# Staged payload stubs and an exhaustive sudo fake exercise the real driver's
# sequencing/exit handler. Unhandled sudo commands fail, never delegate to sudo.
mkdir "$TESTROOT/bin" "$TESTROOT/stage" "$TESTROOT/home"
cp "$HERE/apt-canary-local.sh" "$HERE/verify-evidence.sh" "$HERE/verify-evidence.jq" \
    "$HERE/redact.jq" "$TESTROOT/stage/"
cat > "$TESTROOT/bin/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TESTROOT/sudo-calls"
case "$*" in
    '-v'|'-n -v') exit 0 ;;
    '-n mkdir /var/lib/runix-apt-canary') mkdir "$TESTROOT/attempt-marker" ;;
    '-n cat /var/log/runix/audit.jsonl')
        [ "$TEST_MODE" != export_fail ] || exit 1
        cat "$TESTROOT/audit-raw.jsonl" ;;
    '-n rm -f '*) [ "$TEST_MODE" != cleanup_fail ] ;;
    '-n systemctl restart polkit') exit 0 ;;
    '-n test ! -e '*) [ "$TEST_MODE" != cleanup_fail ] ;;
    '-n dpkg --audit') exit 0 ;;
    *) echo "UNHANDLED FAKE SUDO: $*" >&2; exit 99 ;;
esac
EOF
cat > "$TESTROOT/bin/hostname" <<'EOF'
#!/bin/bash
echo synthetic-disposable
EOF
cat > "$TESTROOT/bin/cat" <<'EOF'
#!/bin/bash
if [ "$#" -eq 1 ] && [ "$1" = /etc/machine-id ]; then
    echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
else
    exec /bin/cat "$@"
fi
EOF
cat > "$TESTROOT/bin/getent" <<'EOF'
#!/bin/bash
exit 2
EOF
cat > "$TESTROOT/bin/dpkg" <<'EOF'
#!/bin/bash
[ "$*" = --audit ] || exit 99
EOF
cat > "$TESTROOT/bin/dpkg-query" <<'EOF'
#!/bin/bash
case "$*" in '-W pkgexec'|'-W runix-audit-broker') exit 1;; esac
echo 'synthetic-package 1.0 install ok installed'
EOF
cat > "$TESTROOT/bin/stat" <<'EOF'
#!/bin/bash
echo 'synthetic-entrypoint root:root 755 123'
EOF
cat > "$TESTROOT/bin/Rscript" <<'EOF'
#!/bin/bash
echo 'synthetic R package versions'
EOF
cat > "$TESTROOT/stage/install-apt-stack.sh" <<'EOF'
#!/bin/bash
[ "$TEST_MODE" != install_fail ] || exit 21
if [ "$TEST_MODE" = install_term ]; then kill -TERM "$PPID"; exit 23; fi
echo 'synthetic install completed'
EOF
cat > "$TESTROOT/stage/apt-fixtures.sh" <<'EOF'
#!/bin/bash
[ "$(umask)" = 0022 ] || { echo 'fixture package permissions would be wrong' >&2; exit 24; }
echo 'synthetic fixtures completed'
EOF
cat > "$TESTROOT/stage/polkit-matrix.sh" <<'EOF'
#!/bin/bash
[ "$TEST_MODE" != matrix_fail ] || exit 22
cat "$TESTROOT/good/03-matrix.log"
EOF
cat > "$TESTROOT/stage/apt-gates.sh" <<'EOF'
#!/bin/bash
touch "$TESTROOT/gates-ran"
cat "$TESTROOT/good/04-gates.log"
EOF
chmod +x "$TESTROOT/bin/"*
for p in runix-audit-broker pkgexec janssonr runix pkgstate pkgops; do
    tar -czf "$TESTROOT/stage/$p.tar.gz" -T /dev/null
done
for f in MANIFEST apt-issue.sh apt-issue.R fcntl-lock.c; do printf 'synthetic\n' > "$TESTROOT/stage/$f"; done
(cd "$TESTROOT/stage" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' \
    | sort | xargs sha256sum > SHA256SUMS)
# Use a clean private HOME for each invocation; never edit the real HOME.
run_driver() {
    env PATH="$TESTROOT/bin:$PATH" HOME="$TESTROOT/home" TEST_MODE="$1" \
        bash "$TESTROOT/stage/apt-canary-local.sh" "$TESTROOT/stage" \
        "${2:-synthetic-disposable}" "${3:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
}
expect_failure run_driver good wrong-host
[ ! -e "$TESTROOT/sudo-calls" ]
ok 'wrong host refused before sudo'
expect_failure run_driver good synthetic-disposable bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
[ ! -e "$TESTROOT/sudo-calls" ]
ok 'wrong machine-id refused before sudo'
cp "$TESTROOT/stage/MANIFEST" "$TESTROOT/original-manifest"
printf 'tampered\n' >> "$TESTROOT/stage/MANIFEST"
expect_failure run_driver good
[ ! -e "$TESTROOT/sudo-calls" ]
cp "$TESTROOT/original-manifest" "$TESTROOT/stage/MANIFEST"
ok 'checksum mismatch refused before sudo'

for mode in matrix_fail install_fail install_term export_fail cleanup_fail good; do
    rm -f "$TESTROOT/gates-ran" "$TESTROOT/sudo-calls"
    if [ -d "$TESTROOT/attempt-marker" ]; then rmdir "$TESTROOT/attempt-marker"; fi
    if [ "$mode" = good ]; then
        run_driver "$mode" > "$TESTROOT/last-output" 2>&1
    else
        expect_failure run_driver "$mode"
    fi
    if [ "$mode" = matrix_fail ] || [ "$mode" = install_fail ] || [ "$mode" = install_term ]; then
        [ ! -e "$TESTROOT/gates-ran" ]
    else
        [ -e "$TESTROOT/gates-ran" ]
    fi
    evid=$(awk '/^Evidence:/ {print $2}' "$TESTROOT/last-output" | tail -1)
    [ -s "$evid/RESULT" ] && [ -s "$evid/SHA256SUMS" ]
    (cd "$evid" && sha256sum --strict -c SHA256SUMS >/dev/null)
    ok "driver $mode: sequencing, result and exit evidence"
done
expect_failure run_driver good
ok 'attempt marker prevents a second run'
echo "$pass harness checks passed"
