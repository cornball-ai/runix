#!/bin/bash
# Read-only validation; safe to run again on the copied evidence bundle.
set -euo pipefail
EVID=${1:?usage: verify-evidence.sh <evidence-directory>}
HERE=$(dirname "$(readlink -f "$0")")
for f in 03-matrix.log 04-gates.log 05-matrix-after.log audit-redacted.jsonl; do
    [ -s "$EVID/$f" ] || { echo "missing/empty evidence: $f" >&2; exit 1; }
done
for f in 03-matrix.log 05-matrix-after.log; do
    grep -Fxq '==== polkit matrix: 23 passed, 0 failed ====' "$EVID/$f"
done
grep -Eq '^==== §7 apt-mutation gates: [1-9][0-9]* passed, 0 failed ====$' "$EVID/04-gates.log"
if grep -Eq '^  FAIL ' "$EVID/03-matrix.log" "$EVID/04-gates.log" "$EVID/05-matrix-after.log"; then
    echo 'failed assertion in evidence' >&2; exit 1
fi
# These receipt-free/preview proofs have no correlation-linked outcome rows.
for gate in G11a G11b G-NEG G-PREV-OWN G-PREV-NOOP; do
    grep -Eq "^  PASS  $gate " "$EVID/04-gates.log"
done
CALLS=$(mktemp)
trap 'rm -f "$CALLS"' EXIT
awk '/^EVIDENCE / {print substr($0,10)}' "$EVID/04-gates.log" > "$CALLS"
jq -s -e --slurpfile calls "$CALLS" -f "$HERE/verify-evidence.jq" \
    "$EVID/audit-redacted.jsonl"
