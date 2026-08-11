#!/bin/bash
# A0-dev: install the Runix stack from LOCAL .deb files (no Runix repository)
# inside the disposable guest. Run IN the guest as `ubuntu` (NOPASSWD sudo). The
# .debs are staged in $SRC by the driver.
#
# Proves the packaging closes the "runs from source" -> "installs as .debs" gap:
# `apt-get install ./*.deb` resolves the whole graph from local files, pulling
# only r-cornball-janssonr (cornball apt repo) and r-base-core (CRAN) as external
# deps, and /usr/bin/rctl comes from the rctl .deb (no manual symlink, no
# littler -- the launcher is Rscript-based; see the A0 plan's littler note).
#
# R >= 4.6 from the CRAN Ubuntu repo: Noble ships r-base-core 4.3, but the
# janssonr .deb needs >= 4.6. This is a real fleet constraint, mirrored from
# r-ci's RAPT backend, not a canary quirk.
#
#   install-debs.sh [deb-dir]        # default /tmp/a0dev
set -euo pipefail
SRC="${1:-/tmp/a0dev}"
log() { echo "== $* =="; }

log "CRAN Ubuntu repo (r-base-core >= 4.6.0); key scoped to this source only"
# Scoped keyring + deb822 Signed-By -- NOT global trusted.gpg.d, so the CRAN key
# authenticates only the CRAN source, nothing else on the system.
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
    | sudo tee /etc/apt/keyrings/cran-ubuntu.asc >/dev/null
sudo tee /etc/apt/sources.list.d/cran.sources >/dev/null <<'EOF'
Types: deb
URIs: https://cloud.r-project.org/bin/linux/ubuntu
Suites: noble-cran40/
Signed-By: /etc/apt/keyrings/cran-ubuntu.asc
Enabled: yes
EOF

# The ONLY unauthenticated source, and deliberately so: the janssonr apt repo is
# still unsigned (Trusted: yes). This is confined to the disposable A0-dev guest
# and must never be used on the fleet -- it is the one experimental exception,
# removed when the signed archive (A0-release) lands.
log "janssonr from the cornball apt repository (EXPERIMENTAL; Trusted: yes)"
sudo tee /etc/apt/sources.list.d/janssonr.sources >/dev/null <<'EOF'
Types: deb
URIs: https://cornball-ai.github.io/janssonr
Suites: noble
Components: main
Trusted: yes
Enabled: yes
EOF
sudo apt-get update -qq

log "R 4.6 base (from CRAN)"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    r-base-core
echo "R: $(R --version | head -1)"

log "install the whole stack from LOCAL files (apt resolves the graph)"
cd "$SRC"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ./runix-stack_*.deb ./r-cornball-*.deb ./runix-audit-broker_*.deb

log "socket-activate the broker (units shipped by its .deb)"
sudo systemctl daemon-reload
sudo systemctl start runix-audit.socket
test -S /run/runix-audit.sock && echo "broker socket present: /run/runix-audit.sock"

log "installed state"
Rscript -e 'for (p in c("janssonr","runix","pkgstate","rsystemd","rctl")) cat(sprintf("  %-10s %s\n", p, as.character(packageVersion(p))))'
echo "broker:      $(dpkg-query -W -f='${Version}' runix-audit-broker 2>/dev/null)"
echo "runix-stack: $(dpkg-query -W -f='${Version}' runix-stack 2>/dev/null)"
echo "rctl on PATH: $(command -v rctl) -> $(readlink -f "$(command -v rctl)")"
echo "littler present? $(dpkg-query -W -f='${Package} ${Version}' littler 2>/dev/null || echo 'no (expected)')"
