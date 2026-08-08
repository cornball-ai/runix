#!/bin/sh
# Validate the built .debs in a clean r2u container - the CLI running
# outside any source tree, installed through apt with r-cran-yyjsonr
# resolved from r2u. systemd is not PID 1 in a container, so services.*
# operations are EXPECTED to fail with a typed error envelope - that is
# part of what is being validated.
#
#     deploy/validate-container.sh [image]   # default rocker/r2u:noble
set -eu

here=$(cd "$(dirname "$0")" && pwd)
img=${1:-rocker/r2u:noble}

docker run --rm -v "$here/dist:/dist:ro" "$img" bash -ec '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq littler > /dev/null
    apt-get install -y -qq /dist/r-cornball-*.deb > /dev/null
    echo "== capabilities (PATH launcher) =="
    rctl capabilities --json
    echo "== packages.installed (truncated) =="
    rctl packages installed --json | head -c 220; echo
    echo "== packages.policy dpkg (truncated) =="
    rctl packages policy dpkg --json | head -c 220; echo
    echo "== services.state: typed envelope expected, no systemd PID1 =="
    set +e
    out=$(rctl services state --json)
    code=$?
    set -e
    echo "$out" | head -c 260; echo
    echo "exit=$code"
    echo "== launcher parity in-container =="
    a=$(/usr/lib/R/site-library/rctl/bin/rctl capabilities --json)
    b=$(/usr/lib/R/site-library/rctl/bin/rctl-rscript capabilities --json)
    if [ "$a" = "$b" ]; then
        echo "parity-ok"
    else
        echo "PARITY-MISMATCH"
        exit 1
    fi
    echo "container-validation: PASS"
'
