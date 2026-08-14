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
#     planner installed from the .deb), not the root pkgexec-plan diagnostic.
#
# No R stack: rab-exercise stands in for pkgops, so this proves the NATIVE helper
# boundary, not the future pkgops integration (recorded honestly in the runbook).
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
# (schema_invalid never opens the cache, so it is deterministic here).
if [ -x /usr/bin/runix-apt-preview ] \
   && printf 'not json' | runix-apt-preview 2>/dev/null | grep -q '"status":"schema_invalid"'; then
    echo "  runix-apt-preview installed from .deb + runs (/usr/bin)"
else
    echo "  MISSING/broken runix-apt-preview (from the pkgexec .deb)"; fail=1
fi
echo "  broker: $(dpkg-query -W -f='${Version}' runix-audit-broker 2>/dev/null)"
echo "  pkgexec: $(dpkg-query -W -f='${Version}' pkgexec 2>/dev/null)"
[ "$fail" -eq 0 ] && echo "install-apt-stack: OK" || { echo "install-apt-stack: FAILED"; exit 1; }
