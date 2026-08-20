#!/bin/bash
# Install the apt-mutation stack inside the disposable canary guest. Run IN the
# guest as `ubuntu` (NOPASSWD sudo). The driver stages two pinned source trees in
# $SRC: `runix-audit-broker/` (from HEAD, effect-receipt capable) and `pkgexec/`
# (from the activation branch). This proves the packaged boundary end to end:
#   - the broker `.deb` (socket-activated) that issues + redeems effect receipts;
#   - the pkgexec `.deb`: nine root-owned entrypoints in /usr/libexec/pkgexec, the
#     unprivileged runix-apt-preview planner in /usr/bin, the polkit policy (nine
#     actions) + rules (two autonomous actions), and the runix-apt-autonomous system
#     group created EMPTY by the maintainer script;
#   - the VM-only rab-exercise lifecycle oracle, built from the same source. The
#     issue-time hash now comes from the PACKAGED runix-apt-preview (the production
#     planner installed from the .deb), not the root pkgexec-plan diagnostic;
#   - the R stack (Part B): R 4.6 + janssonr + pkgstate + runix + pkgops (from the
#     staged sources), plus the apt-issue launcher, so the §7 gates drive the REAL
#     pkgops public path. rab-exercise is RETAINED as the broker/receipt oracle for
#     the gates the issuer cannot express (G11-G15).
#
#   install-apt-stack.sh [src-dir]        # default /tmp/canary-apt
set -euo pipefail
SRC="${1:-/tmp/canary-apt}"
log() { echo "== $* =="; }

log "build prerequisites (broker + pkgexec build deps, polkit, local-repo tools)"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential debhelper fakeroot pkg-config \
    libapt-pkg-dev libjansson-dev libssl-dev \
    polkitd pkexec dpkg-dev apt-utils jq

log "build + install the audit broker .deb (HEAD: effect-receipt capable)"
cd "$SRC/runix-audit-broker"
dpkg-buildpackage -b -us -uc
sudo apt-get install -y "$SRC"/runix-audit-broker_*.deb
sudo systemctl daemon-reload
sudo systemctl start runix-audit.socket
test -S /run/runix-audit.sock && echo "broker socket present: /run/runix-audit.sock"

log "build + install the pkgexec .deb (activation: 9 entrypoints + polkit + group)"
cd "$SRC/pkgexec"
dpkg-buildpackage -b -us -uc
sudo apt-get install -y "$SRC"/pkgexec_*.deb

log "build the VM-only rab-exercise oracle + fcntl lock-holder (NEVER packaged)"
make -C "$SRC/runix-audit-broker" exercise
cc -O2 -Wall -o "$SRC/fcntl-lock.bin" "$SRC/fcntl-lock.c"
sudo install -m 0755 "$SRC/runix-audit-broker/rab-exercise" /usr/local/bin/rab-exercise
sudo install -m 0755 "$SRC/fcntl-lock.bin" /usr/local/bin/fcntl-lock

# --- the R stack (Part B): drive the gates through the real pkgops public path ---
# Mirrors deploy/canary/install-stack.sh: R 4.6 from CRAN (Noble ships 4.3, which the
# janssonr .deb outruns), janssonr from the cornball apt repo, then R CMD INSTALL the
# staged sources in dependency order (pkgops Imports runix + pkgstate + janssonr).
log "R 4.6 from the CRAN Ubuntu repo (Noble ships 4.3; the janssonr .deb needs >= 4.6)"
curl -fsSL https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
    | sudo tee /etc/apt/trusted.gpg.d/cran_ubuntu_key.asc >/dev/null
echo "deb https://cloud.r-project.org/bin/linux/ubuntu noble-cran40/" \
    | sudo tee /etc/apt/sources.list.d/cran.list >/dev/null
sudo apt-get purge -y littler r-cran-littler >/dev/null 2>&1 || true   # ABI-pinned to R 4.3
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    r-base-core r-base-dev
echo "  $(R --version | head -1)"

log "janssonr from the cornball apt repository (runix's one Import)"
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

log "install the R packages from the staged sources (runix + pkgstate, then pkgops)"
cd "$SRC"
for p in runix pkgstate pkgops; do
    rm -rf "$p" && tar xzf "$p.tar.gz"
    sudo R CMD INSTALL "$p"
done

log "install the apt-issue launcher (the pkgops issuer path; VM-only, never packaged)"
sudo install -m 0644 "$SRC/apt-issue.R" /usr/local/bin/apt-issue.R
sudo install -m 0755 "$SRC/apt-issue.sh" /usr/local/bin/apt-issue

log "verify install surface"
fail=0
for v in install remove purge upgrade dist-upgrade update hold unhold configure; do
    p="/usr/libexec/pkgexec/runix-apt-$v"
    if [ ! -x "$p" ]; then
        echo "  MISSING entrypoint: $p"; fail=1
    fi
done
echo "  entrypoints: $(ls /usr/libexec/pkgexec/ | tr '\n' ' ')"
test -f /usr/share/polkit-1/actions/ai.cornball.runix.apt.policy \
    && echo "  polkit policy present" || { echo "  MISSING polkit policy"; fail=1; }
ls /usr/share/polkit-1/rules.d/*runix-apt* >/dev/null 2>&1 \
    && echo "  polkit rules present" || { echo "  MISSING polkit rules"; fail=1; }
if getent group runix-apt-autonomous >/dev/null; then
    members=$(getent group runix-apt-autonomous | cut -d: -f4)
    echo "  group runix-apt-autonomous present, members='${members}'"
    [ -z "$members" ] || { echo "  group is NOT empty at install time"; fail=1; }
else
    echo "  MISSING group runix-apt-autonomous"; fail=1
fi
command -v rab-exercise >/dev/null && command -v fcntl-lock >/dev/null \
    && echo "  rab-exercise + lock-holder on PATH" || { echo "  MISSING oracle"; fail=1; }
# the PRODUCTION planner ships in the pkgexec .deb (on PATH at /usr/bin); the gates
# invoke it unprivileged as aptbot for the issue-time hash. Prove it installed + runs
# (schema_invalid never opens the cache, so it is deterministic here). It exits 1 on
# schema_invalid (exit 0 iff ok/no_op), and this script runs under `set -o pipefail`,
# so a `... | grep` would inherit that nonzero exit even on a MATCH. Capture output +
# rc explicitly (no `|| true`, which would hide an unexpected exit) and assert rc==1
# AND the full strict shape via jq.
PREVOUT=""
PREVRC=127
if [ -x /usr/bin/runix-apt-preview ]; then
    PREVRC=0
    PREVOUT=$(printf 'not json' | /usr/bin/runix-apt-preview 2>/dev/null) \
        || PREVRC=$?
fi
if [ "$PREVRC" -eq 1 ] \
   && jq -e '.schema_version == 1
              and .status == "schema_invalid"
              and .detail == "bad_json"' \
        <<<"$PREVOUT" >/dev/null; then
    echo "  runix-apt-preview installed from .deb + runs (/usr/bin)"
else
    echo "  MISSING/broken runix-apt-preview (from the pkgexec .deb)"; fail=1
fi
echo "  broker: $(dpkg-query -W -f='${Version}' runix-audit-broker 2>/dev/null)"
echo "  pkgexec: $(dpkg-query -W -f='${Version}' pkgexec 2>/dev/null)"
# the R stack + apt-issue launcher (Part B). pkgops must load with its Imports.
for p in janssonr runix pkgstate pkgops; do
    v=$(Rscript -e "cat(as.character(packageVersion('$p')))" 2>/dev/null) \
        && echo "  R $p $v" || { echo "  MISSING R package $p"; fail=1; }
done
{ command -v apt-issue >/dev/null && [ -f /usr/local/bin/apt-issue.R ]; } \
    && echo "  apt-issue launcher on PATH" || { echo "  MISSING apt-issue launcher"; fail=1; }
[ "$fail" -eq 0 ] && echo "install-apt-stack: OK" || { echo "install-apt-stack: FAILED"; exit 1; }
