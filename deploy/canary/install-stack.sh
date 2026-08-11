#!/bin/bash
# Install the pinned Runix stack inside the A1 canary guest. Run IN the guest
# as the `ubuntu` user (NOPASSWD sudo). Sources are pinned tarballs staged in
# $SRC by the driver; janssonr comes from the cornball apt repo; the broker is
# built from its pinned source and socket-activated.
#
# NOTE: the janssonr apt binary is built against R >= 4.6.0, newer than Ubuntu
# Noble's stock r-base-core (4.3.3). So R comes from the CRAN Ubuntu repo
# (marutter), mirroring what r-ci's RAPT backend arranges in CI. This is a real
# deployment constraint for the fleet, not a canary-only quirk.
#
#   install-stack.sh [src-dir]   # default /tmp/canary
set -euo pipefail
SRC="${1:-/tmp/canary}"
log() { echo "== $* =="; }

log "CRAN Ubuntu repo (provides r-base-core >= 4.6.0)"
curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
    | sudo tee /etc/apt/trusted.gpg.d/cran_ubuntu_key.asc >/dev/null
echo "deb https://cloud.r-project.org/bin/linux/ubuntu noble-cran40/" \
    | sudo tee /etc/apt/sources.list.d/cran.list >/dev/null

log "drop Noble littler (ABI-pinned to R 4.3; rctl uses its Rscript launcher)"
sudo apt-get purge -y littler r-cran-littler >/dev/null 2>&1 || true

log "apt prerequisites (R 4.6 toolchain + broker build deps)"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    r-base-core r-base-dev build-essential git \
    libjansson-dev pkg-config debhelper fakeroot
echo "R: $(R --version | head -1)"

log "janssonr from the cornball apt repository (rapt's pattern, Trusted: yes)"
sudo tee /etc/apt/sources.list.d/janssonr.sources >/dev/null <<'EOF'
Types: deb
URIs: https://cornball-ai.github.io/janssonr
Suites: noble
Components: main
Trusted: yes
Enabled: yes
EOF
sudo apt-get update -qq
sudo apt-get install -y r-cornball-janssonr

log "build + install the audit broker .deb, socket-activate it"
cd "$SRC"
rm -rf runix-audit-broker && tar xzf runix-audit-broker.tgz
( cd runix-audit-broker && dpkg-buildpackage -us -uc -b )
sudo dpkg -i runix-audit-broker_*.deb || sudo apt-get install -f -y
sudo systemctl daemon-reload
sudo systemctl start runix-audit.socket
test -S /run/runix-audit.sock && echo "broker socket present: /run/runix-audit.sock"

log "install R packages from pinned sources, in dependency order"
cd "$SRC"
for p in runix pkgstate rsystemd rctl; do
    rm -rf "$p" && tar xzf "$p.tgz"
    sudo R CMD INSTALL "$p"
done

log "expose the rctl launcher on PATH (Rscript variant; no littler)"
sudo chmod 0755 /usr/lib/R/site-library/rctl/bin/rctl-rscript 2>/dev/null || true
sudo ln -sf /usr/lib/R/site-library/rctl/bin/rctl-rscript /usr/bin/rctl

log "installed versions"
Rscript -e 'for (p in c("janssonr","runix","pkgstate","rsystemd","rctl")) cat(sprintf("  %-10s %s\n", p, as.character(packageVersion(p))))'
echo "broker: $(dpkg-query -W -f='${Version}' runix-audit-broker 2>/dev/null)"
echo "rctl on PATH: $(command -v rctl)"
