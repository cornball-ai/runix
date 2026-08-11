#!/bin/bash
# Configure the A1 test fixtures inside the guest. Run IN the guest as `ubuntu`.
#   - an unprivileged principal `canary` (uid 1001, no sudo)
#   - runix-canary.service       : harmless target for preview/restart/audit
#   - runix-canary-slow.service  : slow to activate, for timeout + kill-window
#   - a narrow polkit rule: canary may manage ONLY units named runix-canary*,
#     nothing else
set -euo pipefail
log() { echo "== $* =="; }

log "unprivileged principal canary (uid 1001, no sudo)"
id canary >/dev/null 2>&1 || sudo useradd -m -u 1001 -s /bin/bash canary

log "harmless canary target unit"
sudo tee /etc/systemd/system/runix-canary.service >/dev/null <<'EOF'
[Unit]
Description=Runix A1 canary target (harmless)
[Service]
Type=simple
ExecStart=/usr/bin/sleep infinity
Restart=no
[Install]
WantedBy=multi-user.target
EOF

log "slow-activating canary unit (for timeout / kill-window gates)"
sudo tee /etc/systemd/system/runix-canary-slow.service >/dev/null <<'EOF'
[Unit]
Description=Runix A1 canary slow target (delayed activation)
[Service]
Type=simple
ExecStartPre=/usr/bin/sleep 30
ExecStart=/usr/bin/sleep infinity
Restart=no
EOF

sudo systemctl daemon-reload
sudo systemctl start runix-canary.service

log "narrow polkit policy: canary manages ONLY runix-canary* units"
sudo tee /etc/polkit-1/rules.d/49-runix-canary.rules >/dev/null <<'EOF'
// A1 canary: the unprivileged `canary` principal may manage only the canary
// units. Every other unit, and every other action, falls through to the
// default (deny for an unprivileged, non-interactive caller).
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        subject.user == "canary") {
        var unit = action.lookup("unit");
        if (unit == "runix-canary.service" ||
            unit == "runix-canary-slow.service") {
            return polkit.Result.YES;
        }
        return polkit.Result.NO;
    }
});
EOF
sudo systemctl restart polkit

log "state"
echo "canary uid: $(id -u canary)"
echo "runix-canary.service: $(systemctl is-active runix-canary.service)"
echo "polkit: $(systemctl is-active polkit)"
