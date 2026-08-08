#!/bin/sh
# Build binary .debs for the Runix R packages (pure R, Architecture: all).
# No root required: dpkg-deb --root-owner-group. Package names fit raptd's
# ^r-[a-z]+-[a-z0-9.]+$ allowlist (repo tag "cornball"), so rapt's daemon
# can install them once these land in an apt repo.
#
#     deploy/build-debs.sh [output-dir]     # default: deploy/dist
set -eu

here=$(cd "$(dirname "$0")" && pwd)
dist=${1:-"$here/dist"}
rm -rf "$dist"
mkdir -p "$dist"

build_one() {
    src=$1
    deb=$2
    depends=$3
    recommends=$4
    desc=$5
    ver=$(awk '/^Version:/ { print $2; exit }' "$src/DESCRIPTION")
    pkg=$(awk '/^Package:/ { print $2; exit }' "$src/DESCRIPTION")
    stage=$(mktemp -d)
    lib="$stage/usr/lib/R/site-library"
    mkdir -p "$lib" "$stage/DEBIAN"
    (cd "$stage" && R CMD build --no-build-vignettes --no-manual "$src" \
        > /dev/null 2>&1)
    R CMD INSTALL -l "$lib" "$stage/${pkg}_${ver}.tar.gz" > /dev/null 2>&1
    rm -f "$stage/${pkg}_${ver}.tar.gz"
    {
        printf 'Package: %s\n' "$deb"
        printf 'Version: %s\n' "$ver"
        printf 'Architecture: all\n'
        printf 'Section: gnu-r\n'
        printf 'Priority: optional\n'
        printf 'Maintainer: cornball.ai <troy@cornball.ai>\n'
        printf 'Depends: %s\n' "$depends"
        [ -n "$recommends" ] && printf 'Recommends: %s\n' "$recommends"
        printf 'Homepage: https://github.com/cornball-ai/%s\n' "$pkg"
        printf 'Description: %s\n' "$desc"
        printf ' Part of Runix (https://github.com/cornball-ai/runix),\n'
        printf ' R-native Unix system administration. Experimental.\n'
    } > "$stage/DEBIAN/control"
    if [ "$pkg" = "rctl" ]; then
        mkdir -p "$stage/usr/bin"
        ln -s ../lib/R/site-library/rctl/bin/rctl "$stage/usr/bin/rctl"
        chmod 0755 "$lib/rctl/bin/rctl" "$lib/rctl/bin/rctl-rscript"
    fi
    dpkg-deb --build --root-owner-group "$stage" \
        "$dist/${deb}_${ver}_all.deb" > /dev/null
    rm -rf "$stage"
    echo "built ${deb}_${ver}_all.deb"
}

build_one /home/troy/rdpkg r-cornball-rdpkg \
    "r-base-core" "" \
    "read-only dpkg/apt introspection for R"
build_one /home/troy/rsystemd r-cornball-rsystemd \
    "r-base-core, r-cran-jsonlite" "" \
    "read-only systemd introspection for R"
build_one /home/troy/rctl r-cornball-rctl \
    "r-base-core, r-cran-yyjsonr (>= 0.1.22), littler" \
    "r-cornball-rdpkg, r-cornball-rsystemd" \
    "Runix command-line interface"

(cd "$dist" && dpkg-scanpackages --multiversion . > Packages 2>/dev/null \
    && gzip -kf Packages)
echo "repo index written: $dist/Packages.gz"
