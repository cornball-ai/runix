#!/bin/bash
# Read-only eligibility check for repeating gates after a completed, clean run.
# Full audit acceptance remains verify-evidence.sh's job after the new run.
set -euo pipefail
EVID=${1:?usage: check-completed-gates.sh <previous-evidence>}
die() { echo "REFUSING repeat: $*" >&2; exit 1; }
for f in RESULT MANIFEST INPUT-SHA256SUMS PREVIOUS-MANIFEST PREVIOUS-INPUT-SHA256SUMS \
         resumed-from.txt host.txt 03-matrix.log 04-gates.log 05-matrix-after.log \
         packages-before.tsv packages-after.tsv dpkg-audit.txt audit-export-errors.log \
         audit-redacted.jsonl; do
    [ -f "$EVID/$f" ] || die "missing evidence: $f"
    awk -v name="$f" '$2 == name && length($1) == 64 {found=1} END {exit !found}' \
        "$EVID/SHA256SUMS" || die "missing checksum: $f"
done
(cd "$EVID" && sha256sum --strict -c SHA256SUMS) || die 'previous evidence changed'
for line in run_mode=resume-before-gates phase=complete exit_code=1 cleanup_exit=0 evidence_exit=1; do
    grep -Fxq "$line" "$EVID/RESULT" || die "unexpected previous result: $line"
done
for f in 03-matrix.log 05-matrix-after.log; do
    grep -Fxq '==== polkit matrix: 23 passed, 0 failed ====' "$EVID/$f" \
        || die "previous matrix failed: $f"
done
grep -Eq '^==== §7 apt-mutation gates: [1-9][0-9]* passed, 0 failed ====$' \
    "$EVID/04-gates.log" || die 'previous gates did not complete successfully'
if grep -Eq '^  FAIL ' "$EVID/03-matrix.log" "$EVID/04-gates.log" "$EVID/05-matrix-after.log"; then
    die 'previous assertions failed'
fi
[ ! -s "$EVID/dpkg-audit.txt" ] && [ ! -s "$EVID/audit-export-errors.log" ] \
    || die 'previous package state or export failed'
[ -s "$EVID/audit-redacted.jsonl" ] || die 'previous audit export missing'
cmp "$EVID/packages-before.tsv" "$EVID/packages-after.tsv" \
    || die 'previous gates left package state changes'
echo 'Completed gates and cleanup verified; evidence acceptance still failed'
