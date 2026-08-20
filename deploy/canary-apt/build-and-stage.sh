#!/bin/bash
# Runs on the workstation (where the repos live). Produces a fully REPRODUCIBLE
# staging set: it captures the FIVE commit IDs (broker, pkgexec, runix, pkgstate,
# pkgops) ONCE and sources EVERY artifact from those exact commits with `git archive`
# — the C source tarballs (broker, pkgexec), the R source tarballs (runix, pkgstate,
# pkgops, for Part B's pkgops issuer path) AND the payload scripts/helpers/redactor
# (never the worktree). runix serves double duty: its tree is BOTH the R package
# source (runix.tar.gz) and the payload directory (deploy/canary-apt). It refuses
# unless all five trees are clean, checksums EVERYTHING transferred, and stages into a
# unique, owned directory on the host. Nothing is built here.
#
#   deploy/canary-apt/build-and-stage.sh <kvm-host>     # host is REQUIRED
set -euo pipefail
G5="${1:?usage: build-and-stage.sh <kvm-host>   (no default host; pass it explicitly)}"
BROKER="${BROKER:-/home/troy/runix-audit-broker}"
PKGEXEC="${PKGEXEC:-/home/troy/pkgexec}"
PKGSTATE="${PKGSTATE:-/home/troy/pkgstate}"
PKGOPS="${PKGOPS:-/home/troy/pkgops}"
HERE="$(dirname "$(readlink -f "$0")")"
RUNIX="$(git -C "$HERE" rev-parse --show-toplevel)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "== require clean trees (stage exactly what is committed) =="
for r in "$BROKER" "$PKGEXEC" "$RUNIX" "$PKGSTATE" "$PKGOPS"; do
    if [ -n "$(git -C "$r" status --porcelain)" ]; then
        echo "refusing: $r has uncommitted changes; commit them first" >&2
        git -C "$r" status --short >&2
        exit 1
    fi
done

# Capture the five commit IDs ONCE; every artifact is sourced from these.
BSHA="$(git -C "$BROKER" rev-parse HEAD)"
PSHA="$(git -C "$PKGEXEC" rev-parse HEAD)"
RSHA="$(git -C "$RUNIX" rev-parse HEAD)"
SSHA="$(git -C "$PKGSTATE" rev-parse HEAD)"
OSHA="$(git -C "$PKGOPS" rev-parse HEAD)"

echo "== git archive every artifact from its exact commit =="
git -C "$BROKER" archive --format=tar.gz --prefix=runix-audit-broker/ "$BSHA" \
    > "$STAGE/runix-audit-broker.tar.gz"
git -C "$PKGEXEC" archive --format=tar.gz --prefix=pkgexec/ "$PSHA" \
    > "$STAGE/pkgexec.tar.gz"
# the R sources for Part B's pkgops issuer path: each extracts to <pkg>/ in the guest,
# where install-apt-stack.sh runs `R CMD INSTALL` in dependency order.
git -C "$RUNIX" archive --format=tar.gz --prefix=runix/ "$RSHA" \
    > "$STAGE/runix.tar.gz"
git -C "$PKGSTATE" archive --format=tar.gz --prefix=pkgstate/ "$SSHA" \
    > "$STAGE/pkgstate.tar.gz"
git -C "$PKGOPS" archive --format=tar.gz --prefix=pkgops/ "$OSHA" \
    > "$STAGE/pkgops.tar.gz"
# the payload scripts/helpers/redactor from the RUNIX commit, not the worktree
git -C "$RUNIX" archive "$RSHA" deploy/canary-apt \
    | tar -x -C "$STAGE" --strip-components=2

{
    echo "# canary-apt build manifest"
    printf 'broker    %s (%s)\n' "$BSHA" "$(git -C "$BROKER" rev-parse --abbrev-ref HEAD)"
    printf 'pkgexec   %s (%s)\n' "$PSHA" "$(git -C "$PKGEXEC" rev-parse --abbrev-ref HEAD)"
    printf 'runix     %s (%s)\n' "$RSHA" "$(git -C "$RUNIX" rev-parse --abbrev-ref HEAD)"
    printf 'pkgstate  %s (%s)\n' "$SSHA" "$(git -C "$PKGSTATE" rev-parse --abbrev-ref HEAD)"
    printf 'pkgops    %s (%s)\n' "$OSHA" "$(git -C "$PKGOPS" rev-parse --abbrev-ref HEAD)"
} > "$STAGE/MANIFEST"

echo "== checksum EVERYTHING transferred =="
( cd "$STAGE" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' \
    | sort | xargs sha256sum > SHA256SUMS )
cat "$STAGE/MANIFEST"; echo; cat "$STAGE/SHA256SUMS"

echo "== stage into a unique, owned host directory =="
HOSTSTAGE="$(ssh "$G5" 'mktemp -d "$HOME/canary-apt-stage.XXXXXX"')"
scp "$STAGE"/* "$G5":"$HOSTSTAGE"/
echo "staged at $G5:$HOSTSTAGE"
echo "run:  ssh $G5 bash $HOSTSTAGE/apt-canary-guest.sh $HOSTSTAGE"
