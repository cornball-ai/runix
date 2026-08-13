#!/bin/bash
# Runs ON the KVM host (the designated canary host). Reads the reproducible staging
# set that build-and-stage.sh placed in a unique owned directory (passed as $1),
# verifies its checksums host-side, ships it into a UNIQUE owned guest directory and
# re-verifies there, then builds+installs the stack and runs the polkit matrix + §7
# gates, collecting REDACTED evidence to a fresh per-run directory. The A1 guest must
# already be provisioned (deploy/canary/provision.sh). The host is untouched beyond
# the guest and $HOME/canary{,-stage.*}.
#
#   apt-canary-guest.sh <host-stage-dir>
set -euo pipefail
STAGEDIR="${1:?usage: apt-canary-guest.sh <host-stage-dir>   (from build-and-stage.sh)}"
CANARY="$HOME/canary"
IP=$(cat "$CANARY/guest.ip")
KEY="$CANARY/id_canary"
SSHOPT=(-i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=8 -o LogLevel=ERROR)
guest() { ssh "${SSHOPT[@]}" ubuntu@"$IP" "$@"; }
gscp() { scp "${SSHOPT[@]}" "$@"; }

echo "#### verify the staged artifacts host-side ####"
( cd "$STAGEDIR" && sha256sum -c SHA256SUMS )
EVID="$STAGEDIR/evidence-$(date +%Y%m%dT%H%M%S)-$$"
mkdir -p "$EVID"
cp -f "$STAGEDIR/MANIFEST" "$EVID/MANIFEST"

echo "#### wait for guest ssh ($IP) ####"
for _ in $(seq 1 48); do guest true 2>/dev/null && break; sleep 5; done
guest 'echo guest-ok; . /etc/os-release; echo "$PRETTY_NAME"'

echo "#### stage into a UNIQUE owned guest directory, verify checksums ####"
GDIR=$(guest 'mktemp -d "$HOME/canary-apt.XXXXXX"')
gscp "$STAGEDIR"/* ubuntu@"$IP":"$GDIR"/
guest "cd $GDIR && sha256sum -c SHA256SUMS" | tee "$EVID/00-checksums.log"
guest "cd $GDIR && tar xzf runix-audit-broker.tar.gz && tar xzf pkgexec.tar.gz"

echo "#### install stack (broker@HEAD + pkgexec@activation + VM oracles) ####"
guest "bash $GDIR/install-apt-stack.sh $GDIR" 2>&1 | tee "$EVID/01-install.log"

echo "#### fixtures (aptbot/aptuser, local repo, test packages) ####"
guest "bash $GDIR/apt-fixtures.sh" 2>&1 | tee "$EVID/02-fixtures.log"

echo "#### polkit matrix (5 proofs) ####"
set +e
guest "bash $GDIR/polkit-matrix.sh" 2>&1 | tee "$EVID/03-matrix.log"; M=${PIPESTATUS[0]}
echo "#### §7 apt-mutation gates ####"
guest "bash $GDIR/apt-gates.sh" 2>&1 | tee "$EVID/04-gates.log"; G=${PIPESTATUS[0]}
set -e

echo "#### collect REDACTED evidence (raw sink never leaves the guest) ####"
guest "sudo cat /var/log/runix/audit.jsonl 2>/dev/null | jq -c -f $GDIR/redact.jq" \
    > "$EVID/audit-redacted.jsonl" 2>/dev/null || true
guest 'dpkg -l | grep -E "pkgexec|runix-audit|canary-|r-cornball" || true' > "$EVID/dpkg-state.txt" || true
guest 'stat -c "%n %U:%G %a" /usr/libexec/pkgexec/runix-apt-*' > "$EVID/entrypoint-modes.txt" || true

echo "#### final cleanup: verify no temporary polkit grant remains in the guest ####"
TEMPRULE=/etc/polkit-1/rules.d/49-canary-apt-temp.rules
if guest "test -e $TEMPRULE"; then
    echo "WARNING: a temporary grant survived; removing it now" | tee -a "$EVID/04-gates.log"
    guest "sudo rm -f $TEMPRULE && sudo systemctl restart polkit"
    guest "test ! -e $TEMPRULE" && echo "temp grant removed + verified gone" \
        || { echo "FAILED to remove temp grant" >&2; exit 1; }
else
    echo "no temporary grant remains (verified)"
fi

echo
echo "==== matrix rc=$M   gates rc=$G ===="
echo "evidence: $EVID"
echo "teardown after review: deploy/canary/provision.sh destroy   (owned guest + storage only)"
[ "$M" -eq 0 ] && [ "$G" -eq 0 ]
