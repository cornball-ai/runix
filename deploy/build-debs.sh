#!/bin/sh
# deploy/build-debs.sh -- A0-dev debhelper orchestrator for the Runix stack.
#
# Builds real .debs from the current package sources with debhelper
# (dpkg-buildpackage), not hand-rolled control files. For each R package it
#   - assembles a clean source tree (R CMD build, honoring .Rbuildignore),
#   - drops in the deploy/debian/<debname>/ template and a generated changelog,
#   - stage-installs into a shared R library (dependency order) so the next
#     package's lazy-load DB resolves its Imports,
#   - builds via dpkg-buildpackage, emitting the binary .deb AND the source
#     package + .buildinfo.
# It also builds the audit broker (from its own in-repo debian/) and the
# runix-stack metapackage, then records artifact SHA-256 sums and the source
# commits pinned into the build.
#
#     deploy/build-debs.sh [output-dir]        # default: deploy/dist
#
# A0-dev only: local files on disposable VMs. No signing, no repository publish,
# no "Trusted: yes". Native source format (3.0 native; version == R version);
# non-native "-1" revisions + orig tarballs arrive with the Debian submission.
#
# Dependency resolution: janssonr is NOT built here (its packaging is the
# janssonr repo's); the build resolves it from the local R library or an
# apt-installed r-cornball-janssonr already on the R search path. dpkg build-dep
# checking is skipped (-d) because the r-cornball-* build-deps are resolved via
# the R library, not apt; a clean-VM build that apt-installs them first can drop
# -d. R hardening/reproducibility (SOURCE_DATE_EPOCH) is an A0-release concern.
set -eu

here=$(cd "$(dirname "$0")" && pwd)            # runix/deploy
repo=$(cd "$here/.." && pwd)                    # runix
sib=$(cd "$repo/.." && pwd)                     # parent of the sibling checkouts
tpl="$here/debian"                              # deploy/debian/<debname>/
dist=${1:-"$here/dist"}
stack_ver=${STACK_VERSION:-0.0.1}               # runix-stack metapackage version
# Optional rebuild marker: DEB_BUILDNO=2 -> versions gain "+build2"
# (0.0.1.8+build2 > 0.0.1.8 in dpkg ordering), so a second build is a genuine
# apt upgrade of the first. Not "+b2": dpkg treats a trailing "+b<digits>" as a
# binary-only NMU, splitting off a source version that a native package lacks.
# Applies to the R packages and the metapackage; the broker keeps its own
# in-repo changelog version.
suf=${DEB_BUILDNO:++build$DEB_BUILDNO}

# Source checkouts (override any via env for a pinned build).
SRC_runix=${SRC_runix:-$repo}
SRC_pkgstate=${SRC_pkgstate:-$sib/pkgstate}
SRC_rsystemd=${SRC_rsystemd:-$sib/rsystemd}
SRC_rctl=${SRC_rctl:-$sib/rctl}
SRC_broker=${SRC_broker:-$sib/runix-audit-broker}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# R_LIBS (prepended, unlike R_LIBS_USER which would replace the user library
# that holds janssonr) adds the staging dir ahead of the machine's libraries.
export R_LIBS="$work/rlib"
mkdir -p "$R_LIBS"

DIST_MARKER=".runix-build-output"

# Refuse to rm -rf anything but a directory this script created (or a fresh
# path). Mirrors provision.sh's ownership-marker teardown: an unmarked existing
# directory is never ours to delete, and sensitive roots are refused outright.
safe_prepare_dist() {   # <output-dir>
    d=$1
    [ -n "$d" ] || { echo "refusing: empty output dir" >&2; exit 2; }
    if [ -e "$d" ]; then
        rp=$(cd "$d" && pwd)
        case "$rp" in
            "/" | "$HOME" | "$repo" | "$here" | "$sib")
                echo "refusing: '$rp' is a protected directory, not build output" >&2
                exit 2 ;;
        esac
        if [ ! -f "$rp/$DIST_MARKER" ]; then
            echo "refusing to rm -rf '$rp': no $DIST_MARKER marker -- not an" >&2
            echo "  owned build-output dir. Remove it yourself if it is stale." >&2
            exit 2
        fi
        rm -rf "$rp"
    fi
    mkdir -p "$d"
    printf 'Owned by deploy/build-debs.sh. Safe to delete; recreated each build.\n' \
        > "$d/$DIST_MARKER"
}

# Honest provenance: R CMD build consumes the WORKING TREE, so a recorded commit
# only identifies the artifact when the tree is clean. Refuse a dirty/untracked
# source tree. ALLOW_DIRTY overrides for local iteration, and the manifest then
# records the source as unpinned rather than lying with a commit that was not
# what was built.
require_clean() {   # <srcdir> <label>
    d=$1; lbl=$2
    if ! git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "refusing: $lbl source '$d' is not a git work tree (no provenance)" >&2
        exit 2
    fi
    [ -z "$(git -C "$d" status --porcelain)" ] && return 0
    echo "refusing: $lbl source '$d' has uncommitted or untracked changes." >&2
    echo "  R CMD build would bake the working tree in, so the pinned commit" >&2
    echo "  would misidentify the build. Commit or stash first." >&2
    [ -n "${ALLOW_DIRTY:-}" ] || exit 2
    echo "  ALLOW_DIRTY set: continuing; $lbl provenance recorded as UNPINNED." >&2
}

gen_changelog() {   # <debname> <version> <treedir>
    mkdir -p "$3/debian"
    {
        printf '%s (%s) unstable; urgency=medium\n\n' "$1" "$2"
        printf '  * A0-dev local build.\n\n'
        printf ' -- Troy Hernandez <troy@cornball.ai>  %s\n' "$(date -R)"
    } > "$3/debian/changelog"
}

collect() {         # <debname> <version> : move build products into $dist
    found_deb=0
    for f in "$work/$1_$2_"*.deb "$work/$1_$2.dsc" "$work/$1_$2.tar."* \
             "$work/$1_$2_"*.buildinfo "$work/$1_$2_"*.changes; do
        [ -e "$f" ] || continue
        case "$f" in *.deb) found_deb=1 ;; esac
        mv "$f" "$dist/"
    done
    # Fail closed: a build that produced no binary is an error, not a skip.
    [ "$found_deb" = 1 ] || {
        echo "ERROR: no .deb produced for $1 ($2)" >&2; exit 1; }
}

build_r_pkg() {     # <srcdir> <debname>
    src=$1; deb=$2
    require_clean "$src" "$deb"
    ver=$(awk '/^Version:/{print $2; exit}' "$src/DESCRIPTION")
    pkg=$(awk '/^Package:/{print $2; exit}' "$src/DESCRIPTION")
    dver="${ver}${suf}"
    ( cd "$work" && R CMD build --no-build-vignettes --no-manual "$src" >/dev/null )
    tarball="$work/${pkg}_${ver}.tar.gz"
    # Stage-install so packages built later resolve this one as an Import.
    R CMD INSTALL --library="$R_LIBS" "$tarball" >/dev/null 2>&1
    ( cd "$work" && tar -xzf "$tarball" )       # -> $work/$pkg/
    btree="$work/$pkg"
    mkdir -p "$btree/debian"
    cp -a "$tpl/$deb/." "$btree/debian/"
    gen_changelog "$deb" "$dver" "$btree"
    ( cd "$btree" && dpkg-buildpackage -us -uc -d )
    collect "$deb" "$dver"
    printf '%s %s\n' "$deb" "$dver" >> "$work/versions"
    rm -rf "$btree"
    echo "built $deb ($dver)"
}

build_broker() {    # <srcdir>
    src=$1
    # Fail closed: a missing broker source is an error -- the metapackage
    # depends on the broker, so silently skipping it would ship a broken stack.
    [ -d "$src" ] || { echo "ERROR: broker source '$src' not found" >&2; exit 1; }
    require_clean "$src" runix-audit-broker
    ver=$(awk 'NR==1{gsub(/[()]/,"",$2); print $2; exit}' "$src/debian/changelog")
    btree="$work/runix-audit-broker"
    mkdir -p "$btree"
    ( cd "$src" && git archive --format=tar HEAD ) | tar -x -C "$btree"
    ( cd "$btree" && dpkg-buildpackage -us -uc -d )
    collect runix-audit-broker "$ver"
    printf 'runix-audit-broker %s\n' "$ver" >> "$work/versions"
    rm -rf "$btree"
    echo "built runix-audit-broker ($ver)"
}

build_meta() {      # runix-stack: EXACT-version closure over the stack just built
    deb=runix-stack; ver="${stack_ver}${suf}"
    # Pre-0.1, exact (=) versions are safest: the metapackage then identifies the
    # precise stack this run built (and the canary proved), not "some newer set".
    lookup() { awk -v k="$1" '$1==k{print $2; exit}' "$work/versions"; }
    runix_v=$(lookup r-cornball-runix)
    rctl_v=$(lookup r-cornball-rctl)
    pkgstate_v=$(lookup r-cornball-pkgstate)
    rsystemd_v=$(lookup r-cornball-rsystemd)
    broker_v=$(lookup runix-audit-broker)
    # Pin the core (runix) too: the subsystems depend on r-cornball-runix
    # UNVERSIONED, so without this the metapackage would leave the tested core
    # unconstrained and apt could resolve a different one.
    for nv in "runix:$runix_v" "rctl:$rctl_v" "pkgstate:$pkgstate_v" \
              "rsystemd:$rsystemd_v" "broker:$broker_v"; do
        [ -n "${nv#*:}" ] || {
            echo "ERROR: metapackage closure missing version for ${nv%%:*}" >&2
            exit 1; }
    done
    RUNIX_STACK_DEPENDS="r-cornball-runix (= $runix_v), r-cornball-rctl (= $rctl_v), r-cornball-pkgstate (= $pkgstate_v), r-cornball-rsystemd (= $rsystemd_v), runix-audit-broker (= $broker_v)"
    export RUNIX_STACK_DEPENDS
    btree="$work/$deb"
    mkdir -p "$btree/debian"
    cp -a "$tpl/$deb/." "$btree/debian/"
    printf 'Runix stack metapackage. See https://github.com/cornball-ai/runix\n' \
        > "$btree/README"
    gen_changelog "$deb" "$ver" "$btree"
    ( cd "$btree" && dpkg-buildpackage -us -uc -d )
    collect "$deb" "$ver"
    rm -rf "$btree"
    echo "built $deb ($ver)"
    echo "  closure: $RUNIX_STACK_DEPENDS"
}

safe_prepare_dist "$dist"

# Build order: runix first (the common Import), then the subsystems, then rctl.
build_r_pkg "$SRC_runix"    r-cornball-runix
build_r_pkg "$SRC_pkgstate" r-cornball-pkgstate
build_r_pkg "$SRC_rsystemd" r-cornball-rsystemd
build_r_pkg "$SRC_rctl"     r-cornball-rctl
build_broker "$SRC_broker"
build_meta

# Fail closed: exactly the six expected binaries must be present.
missing=
for p in r-cornball-runix r-cornball-pkgstate r-cornball-rsystemd r-cornball-rctl \
         runix-audit-broker runix-stack; do
    set -- "$dist/${p}_"*.deb
    [ -e "$1" ] || missing="$missing $p"
done
[ -z "$missing" ] || {
    echo "ERROR: build did not produce .debs for:$missing" >&2; exit 1; }
count=$(ls -1 "$dist"/*.deb | wc -l)
[ "$count" -eq 6 ] || {
    echo "ERROR: expected 6 .debs, found $count in $dist" >&2; exit 1; }

# Provenance: PINNED only if every source tree was clean at build time.
prov=PINNED
for d in "$SRC_runix" "$SRC_pkgstate" "$SRC_rsystemd" "$SRC_rctl" "$SRC_broker"; do
    [ -z "$(git -C "$d" status --porcelain 2>/dev/null)" ] || prov=UNPINNED
done

# MANIFEST: human-readable provenance (source commits + clean/dirty).
{
    printf '# Runix A0-dev build manifest\n'
    printf '# built: %s\n' "$(date -R)"
    printf 'provenance: %s\n\n' "$prov"
    printf '# source commits\n'
    for pair in "runix:$SRC_runix" "pkgstate:$SRC_pkgstate" \
                "rsystemd:$SRC_rsystemd" "rctl:$SRC_rctl" \
                "runix-audit-broker:$SRC_broker"; do
        name=${pair%%:*}; d=${pair#*:}
        rev=$(git -C "$d" rev-parse HEAD 2>/dev/null || echo "no-git")
        if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
            printf '%-20s %s  DIRTY (unpinned)\n' "$name" "$rev"
        else
            printf '%-20s %s  clean\n' "$name" "$rev"
        fi
    done
    printf '\n# verify artifacts with:  sha256sum -c SHA256SUMS\n'
} > "$dist/MANIFEST"

# SHA256SUMS: machine-checkable hashes of EVERY emitted artifact -- binaries,
# source packages, .buildinfo, and .changes.
( cd "$dist" && sha256sum *.deb *.dsc *.tar.* *.buildinfo *.changes 2>/dev/null ) \
    > "$dist/SHA256SUMS"

echo
echo "artifacts in $dist (provenance: $prov):"
ls -1 "$dist"/*.deb
echo "manifest: $dist/MANIFEST   checksums: $dist/SHA256SUMS"
