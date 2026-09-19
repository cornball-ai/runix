#!/bin/bash
# Independent eligibility fixtures; no SSH, sudo, dpkg, apt, or broker calls.
set -euo pipefail
HERE=$(dirname "$(readlink -f "$0")")
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
mkdir "$ROOT/good"
for f in MANIFEST INPUT-SHA256SUMS PREVIOUS-MANIFEST PREVIOUS-INPUT-SHA256SUMS \
         resumed-from.txt host.txt packages-before.tsv packages-after.tsv; do
    printf 'synthetic\n' > "$ROOT/good/$f"
done
printf '%s\n' run_mode=resume-before-gates phase=complete exit_code=1 cleanup_exit=0 evidence_exit=1 \
    > "$ROOT/good/RESULT"
for f in 03-matrix.log 05-matrix-after.log; do
    printf '==== polkit matrix: 23 passed, 0 failed ====\n' > "$ROOT/good/$f"
done
printf '==== §7 apt-mutation gates: 68 passed, 0 failed ====\n' > "$ROOT/good/04-gates.log"
printf '{}\n' > "$ROOT/good/audit-redacted.jsonl"
: > "$ROOT/good/dpkg-audit.txt"
: > "$ROOT/good/audit-export-errors.log"
checksum() {
    (cd "$1" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' \
        | sort | xargs sha256sum > SHA256SUMS)
}
checksum "$ROOT/good"
bash "$HERE/check-completed-gates.sh" "$ROOT/good" > "$ROOT/output"
echo 'PASS completed and cleaned run eligible for a guarded repeat'
count=1
for mode in tampered missing_checksum matrix gate_failure dirty_dpkg export_error package_change incomplete_result; do
    cp -r "$ROOT/good" "$ROOT/bad"
    case "$mode" in
        tampered) printf 'modified\n' >> "$ROOT/bad/host.txt" ;;
        missing_checksum)
            awk '$2 != "RESULT"' "$ROOT/good/SHA256SUMS" > "$ROOT/bad/SHA256SUMS" ;;
        matrix) printf 'failed\n' > "$ROOT/bad/05-matrix-after.log" ;;
        gate_failure) printf '  FAIL G3 wrong state\n' >> "$ROOT/bad/04-gates.log" ;;
        dirty_dpkg) printf 'half-configured fixture\n' > "$ROOT/bad/dpkg-audit.txt" ;;
        export_error) printf 'export failed\n' > "$ROOT/bad/audit-export-errors.log" ;;
        package_change) printf 'fixture still installed\n' > "$ROOT/bad/packages-after.tsv" ;;
        incomplete_result) printf 'phase=gates\n' > "$ROOT/bad/RESULT" ;;
    esac
    case "$mode" in tampered|missing_checksum) ;; *) checksum "$ROOT/bad";; esac
    if bash "$HERE/check-completed-gates.sh" "$ROOT/bad" > "$ROOT/output" 2>&1; then
        echo "unexpected repeat eligibility: $mode" >&2
        exit 1
    fi
    rm -r "$ROOT/bad"
    count=$((count+1))
    echo "PASS repeat refuses $mode"
done
echo "$count completed-run checks passed"
