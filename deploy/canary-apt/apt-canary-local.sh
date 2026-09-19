#!/bin/bash
# DESTRUCTIVE. Run as the ordinary operator on an explicitly approved disposable
# host. The operator supplies identity read independently before staging.
# Usage: bash apt-canary-local.sh <stage-dir> <expected-hostname> <expected-machine-id>
set -euo pipefail
# Build/fixture directories become package contents and must be world-readable.
# Evidence privacy comes from mktemp's mode-0700 directory, not a build-wide mask.
umask 022
[ "$#" -eq 3 ] || { echo "usage: $0 <stage-dir> <expected-hostname> <expected-machine-id>" >&2; exit 2; }
STAGEDIR=$(realpath -e "$1")
EXPECTED_HOST=$2
EXPECTED_ID=$3
die() { echo "REFUSING: $*" >&2; exit 1; }
[[ "$EXPECTED_ID" =~ ^[0-9a-f]{32}$ ]] || die 'invalid expected machine-id'
[ "$(hostname)" = "$EXPECTED_HOST" ] || die 'hostname mismatch'
[ "$(cat /etc/machine-id)" = "$EXPECTED_ID" ] || die 'machine-id mismatch'
[ "$(id -u)" -ne 0 ] || die 'invoke as the ordinary operator, not root'
[ "$(realpath -e "$0")" = "$STAGEDIR/apt-canary-local.sh" ] || die 'run the staged driver'
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die 'this harness requires Ubuntu'

# These checks precede sudo and every host mutation. The root-owned attempt marker
# below survives interrupted runs: another full attempt requires OS reprovisioning.
for who in aptbot aptuser 1002 1003; do
    if getent passwd "$who" >/dev/null; then die "canary principal/uid already exists: $who"; fi
done
if getent group runix-apt-autonomous >/dev/null; then die 'autonomous group already exists'; fi
for p in /var/lib/runix-apt-canary /var/log/runix /run/runix-audit.sock \
         /srv/canary-repo /srv/canary-signed /srv/canary-inline.sources \
         /etc/apt/sources.list.d/canary-*.sources \
         /etc/apt/preferences.d/99-canary-g5-pin \
         /etc/polkit-1/rules.d/49-canary-apt-temp.rules; do
    [ ! -e "$p" ] || die "existing canary/Runix state: $p"
done
AUDIT=$(dpkg --audit)
[ -z "$AUDIT" ] || die "dpkg is not clean: $AUDIT"
for p in pkgexec runix-audit-broker; do
    if dpkg-query -W "$p" >/dev/null 2>&1; then die "existing package: $p"; fi
done

cd "$STAGEDIR"
# An omitted checksum must not turn an unverified payload into a trusted one.
for f in MANIFEST apt-canary-local.sh install-apt-stack.sh apt-fixtures.sh \
         polkit-matrix.sh machine-refusal.R apt-gates.sh redact.jq verify-evidence.sh verify-evidence.jq \
         apt-issue.sh apt-issue.R fcntl-lock.c \
         runix-audit-broker.tar.gz pkgexec.tar.gz janssonr.tar.gz runix.tar.gz \
         pkgstate.tar.gz pkgops.tar.gz; do
    awk -v name="$f" '$2 == name && length($1) == 64 {found=1} END {exit !found}' SHA256SUMS \
        || die "missing checksum: $f"
done
sha256sum --strict -c SHA256SUMS
mkdir -p "$HOME/canary-apt"
EVID=$(mktemp -d "$HOME/canary-apt/evidence-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
cp MANIFEST "$EVID/MANIFEST"
cp SHA256SUMS "$EVID/INPUT-SHA256SUMS"
sha256sum --strict -c SHA256SUMS > "$EVID/00-checksums.log"
{ hostname; cat /etc/machine-id /etc/os-release; uname -a; id; } > "$EVID/host.txt"
dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' > "$EVID/packages-before.tsv"
PHASE=preflight
MUTATION_STARTED=0
GATES_STARTED=0
KEEPALIVE=''

finish() {
    local rc=$? cleanup_rc=0 evidence_rc=0
    trap - EXIT INT TERM HUP
    set +e
    if [ "$MUTATION_STARTED" -eq 1 ]; then
        # Only paths reserved by this harness are removed. Never repair dpkg here:
        # a broken fixture is evidence, and a failed run needs a fresh baseline.
        if [ "$GATES_STARTED" -eq 1 ]; then
            sudo -n rm -f /etc/polkit-1/rules.d/49-canary-apt-temp.rules \
                /etc/apt/preferences.d/99-canary-g5-pin \
                /etc/apt/sources.list.d/canary-broken.sources \
                /etc/apt/sources.list.d/canary-drift.sources \
                /etc/apt/sources.list.d/canary-inline.sources >> "$EVID/cleanup.log" 2>&1 || cleanup_rc=1
            sudo -n systemctl restart polkit >> "$EVID/cleanup.log" 2>&1 || cleanup_rc=1
            for p in /etc/polkit-1/rules.d/49-canary-apt-temp.rules \
                     /etc/apt/preferences.d/99-canary-g5-pin \
                     /etc/apt/sources.list.d/canary-broken.sources \
                     /etc/apt/sources.list.d/canary-drift.sources \
                     /etc/apt/sources.list.d/canary-inline.sources; do
                sudo -n test ! -e "$p" >> "$EVID/cleanup.log" 2>&1 || cleanup_rc=1
            done
            bash "$STAGEDIR/polkit-matrix.sh" > "$EVID/05-matrix-after.log" 2>&1 || cleanup_rc=1
        fi
        sudo -n cat /var/log/runix/audit.jsonl 2> "$EVID/audit-export-errors.log" \
            | jq -c -f "$STAGEDIR/redact.jq" > "$EVID/audit-redacted.jsonl" \
                2>> "$EVID/audit-export-errors.log" || evidence_rc=1
        dpkg-query -W -f='${binary:Package}\t${Version}\t${Status}\n' \
            > "$EVID/packages-after.tsv" || evidence_rc=1
        sudo -n dpkg --audit > "$EVID/dpkg-audit.txt" 2>&1 || cleanup_rc=1
        [ ! -s "$EVID/dpkg-audit.txt" ] || cleanup_rc=1
        stat -c '%n %U:%G %a %i' /usr/libexec/pkgexec/runix-apt-* \
            > "$EVID/entrypoint-modes.txt" 2>&1 || evidence_rc=1
        Rscript --vanilla -e 'cat(R.version.string, "\n"); for (p in c("janssonr", "runix", "pkgstate", "pkgops")) { ns <- loadNamespace(p); cat(p, as.character(getNamespaceVersion(ns)), getNamespaceInfo(ns, "path"), "\n") }' \
            > "$EVID/r-packages.txt" 2>&1 || evidence_rc=1
        if [ "$PHASE" = complete ]; then
            bash "$STAGEDIR/verify-evidence.sh" "$EVID" > "$EVID/verification.log" 2>&1 || evidence_rc=1
        else
            evidence_rc=1
        fi
    else
        evidence_rc=1
    fi
    if [ -n "$KEEPALIVE" ]; then kill "$KEEPALIVE" 2>/dev/null; wait "$KEEPALIVE" 2>/dev/null; fi
    [ "$cleanup_rc" -eq 0 ] && [ "$evidence_rc" -eq 0 ] || rc=1
    printf 'phase=%s\nexit_code=%s\ncleanup_exit=%s\nevidence_exit=%s\n' \
        "$PHASE" "$rc" "$cleanup_rc" "$evidence_rc" > "$EVID/RESULT"
    (cd "$EVID" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' \
        | sort | xargs sha256sum > SHA256SUMS) || rc=1
    echo "Evidence: $EVID"
    echo "Copy and verify this bundle off the disposable host before reinstalling."
    echo "Canary exit: $rc (phase=$PHASE cleanup=$cleanup_rc evidence=$evidence_rc)"
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "Disposable target verified: $EXPECTED_HOST / $EXPECTED_ID"
echo "Evidence: $EVID"
sudo -v
(while sleep 30; do sudo -n -v || exit; done) &
KEEPALIVE=$!
# Atomic, root-owned marker; never removed by the harness.
sudo -n mkdir /var/lib/runix-apt-canary
MUTATION_STARTED=1
tar xzf runix-audit-broker.tar.gz
tar xzf pkgexec.tar.gz
PHASE=install
bash "$STAGEDIR/install-apt-stack.sh" "$STAGEDIR" 2>&1 | tee "$EVID/01-install.log"
PHASE=fixtures
bash "$STAGEDIR/apt-fixtures.sh" 2>&1 | tee "$EVID/02-fixtures.log"
PHASE=matrix
bash "$STAGEDIR/polkit-matrix.sh" 2>&1 | tee "$EVID/03-matrix.log"
PHASE=gates
GATES_STARTED=1
bash "$STAGEDIR/apt-gates.sh" 2>&1 | tee "$EVID/04-gates.log"
PHASE=complete
