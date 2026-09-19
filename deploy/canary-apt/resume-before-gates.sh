#!/bin/bash
# Only continue a completed bootstrap whose destructive gates never started.
# Called by the identity-checked local driver; never reads the old matrix log.
set -euo pipefail
[ "$#" -eq 4 ] || exit 2
MODE=$1
STAGE=$2
OLD=$3
EVID=$4
die() { echo "REFUSING continuation: $*" >&2; exit 1; }
case "$MODE" in check|refresh) ;; *) exit 2;; esac

for f in MANIFEST INPUT-SHA256SUMS host.txt 01-install.log 02-fixtures.log; do
    [ -s "$EVID/$f" ] || die "missing previous setup evidence: $f"
done
[ ! -e "$EVID/04-gates.log" ] || die 'previous destructive gates were entered'
grep -Fxq 'install-apt-stack: OK' "$EVID/01-install.log" || die 'bootstrap did not complete'
grep -Fxq 'apt-fixtures: OK' "$EVID/02-fixtures.log" || die 'fixtures did not complete'
[ "$(head -1 "$EVID/host.txt")" = "$(hostname)" ] || die 'previous hostname mismatch'
[ "$(sed -n '2p' "$EVID/host.txt")" = "$(cat /etc/machine-id)" ] || die 'previous machine-id mismatch'
cmp "$EVID/MANIFEST" "$OLD/MANIFEST" || die 'previous source identity mismatch'
cmp "$EVID/INPUT-SHA256SUMS" "$OLD/SHA256SUMS" || die 'previous input checksums mismatch'
(cd "$OLD" && sha256sum --strict -c SHA256SUMS) || die 'previous bundle changed'
for source in broker pkgexec; do
    prior=$(awk -v s="$source" '$1 == s {print $2}' "$OLD/MANIFEST")
    current=$(awk -v s="$source" '$1 == s {print $2}' "$STAGE/MANIFEST")
    [[ "$prior" =~ ^[0-9a-f]{40}$ ]] && [ "$prior" = "$current" ] \
        || die "native source changed: $source"
done
[ "$(id -u aptbot)" = 1002 ] && [ "$(id -u aptuser)" = 1003 ] || die 'fixture uid mismatch'
[ "$(getent group runix-apt-autonomous | cut -d: -f4)" = aptbot ] || die 'unexpected autonomous members'
case " $(id -nG aptuser) " in *' runix-apt-autonomous '*) die 'aptuser is enrolled';; esac
[ -z "$(dpkg --audit)" ] || die 'dpkg is not clean'
for p in canary-benign canary-badpost canary-slow; do
    status=$(dpkg-query -W -f='${Status}' "$p" 2>/dev/null || true)
    case "$status" in ''|'unknown ok not-installed') ;; *) die "$p already has package state: $status";; esac
done
for p in canary-protected r-cornball-canary; do
    [ "$(dpkg-query -W -f='${Version} ${Status}' "$p")" = '1.0 install ok installed' ] \
        || die "fixture package mismatch: $p"
done
for p in pkgexec runix-audit-broker; do
    debs=("$OLD/${p}_"*.deb)
    [ "${#debs[@]}" -eq 1 ] && [ -f "${debs[0]}" ] || die "missing previous deb: $p"
    [ "$(dpkg-query -W -f='${Status}' "$p")" = 'install ok installed' ] || die "$p not installed"
    [ "$(dpkg-query -W -f='${Version}' "$p")" = "$(dpkg-deb -f "${debs[0]}" Version)" ] \
        || die "installed native version mismatch: $p"
    result=$(dpkg --verify "$p") || die "cannot verify installed $p"
    [ -z "$result" ] || die "installed native files changed: $p"
done
cmp "$OLD/runix-audit-broker/rab-exercise" /usr/local/bin/rab-exercise || die 'oracle changed'
cmp "$OLD/fcntl-lock.bin" /usr/local/bin/fcntl-lock || die 'lock helper changed'
[ -S /run/runix-audit.sock ] || die 'broker socket unavailable'
[ -f /srv/canary-inline.sources ] && [ -f /srv/canary-repo/Packages ] || die 'fixture repository missing'
if [ "$MODE" = check ]; then
    echo 'Continuation preflight: completed setup, unchanged native stack, no gate package changes'
    exit 0
fi

# Check root-only state with root credentials, before changing anything. Keep
# the original attempt marker; an atomic second marker permits ONE continuation.
sudo -n test -d /var/lib/runix-apt-canary || die 'previous attempt marker missing'
for p in /var/lib/runix-apt-canary/gates-started \
         /etc/polkit-1/rules.d/49-canary-apt-temp.rules \
         /etc/apt/preferences.d/99-canary-g5-pin \
         /etc/apt/sources.list.d/canary-broken.sources \
         /etc/apt/sources.list.d/canary-drift.sources \
         /etc/apt/sources.list.d/canary-inline.sources; do
    sudo -n test ! -e "$p" || die "leftover gate state: $p"
done
for lock in /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock; do
    sudo -n test -f "$lock" || die "missing apt/dpkg lock file: $lock"
    sudo -n fcntl-lock "$lock" 0 || die "apt/dpkg lock is held: $lock"
done
sudo -n mkdir /var/lib/runix-apt-canary/resume-before-gates \
    || die 'a continuation was already attempted; inspect its evidence first'

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT
versions=()
for p in janssonr runix pkgstate pkgops; do
    tar xzf "$STAGE/$p.tar.gz" -C "$BUILD"
    version=$(awk '/^Version: / {print $2}' "$BUILD/$p/DESCRIPTION")
    [[ "$version" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "invalid staged R version: $p"
    versions+=("$p=$version")
    sudo -n R CMD INSTALL "$BUILD/$p"
done
sudo -n install -m 0644 "$STAGE/apt-issue.R" /usr/local/bin/apt-issue.R
sudo -n install -m 0755 "$STAGE/apt-issue.sh" /usr/local/bin/apt-issue
# The old inline-key preflight used the global lists directory and cleaned the
# normal indexes. Restore them before any real public-API preview is attempted.
sudo -n apt-get update -o APT::Update::Error-Mode=any -qq
versions_found=$(LC_ALL=C apt-cache madison canary-benign | awk '{print $3}' | sort -u | paste -sd ' ')
[ "$versions_found" = '1.0 1.1' ] || die 'canary-benign indexes are incomplete'
sudo -n -u aptbot Rscript --vanilla -e '
for (pair in commandArgs(TRUE)) {
    x <- strsplit(pair, "=", fixed = TRUE)[[1L]]
    ns <- loadNamespace(x[[1L]])
    stopifnot(as.character(getNamespaceVersion(ns)) == x[[2L]])
    cat(x[[1L]], x[[2L]], getNamespaceInfo(ns, "path"), "\n")
}' "${versions[@]}"
echo 'Continuation setup: repaired R sources installed; fixture indexes restored'
