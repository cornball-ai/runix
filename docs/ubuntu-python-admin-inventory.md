# Ubuntu Python Administrative Tool Inventory

Phase 0 deliverable per `PLAN.md`. Answers: **which first-party administrative
capabilities depend on Python?** (Not: which packages contain Python.)

**Provenance:** surveyed 2026-08-07 on Ubuntu 24.04.4 LTS (noble), headless server with
some desktop packages installed. Every Ubuntu-column claim below traces to a command run
or file read on this machine (see per-record Evidence lines and Appendix B). Scope is
**installed** packages only; archive-only tools are out of scope. Cross-distro and KDE
columns are knowledge-based (no network, no KDE on this box) and marked accordingly.

## Method

Five enumeration sweeps, unioned (raw outputs summarized in Appendix B):

- **A. Shebang scan**: `find /usr/bin /usr/sbin /usr/libexec -maxdepth 2 -type f -exec awk 'FNR==1 && /^#!.*python/ {print FILENAME} {nextfile}' {} +`
  Limitation: `-maxdepth 2`, PATH bin dirs only; sweep E catches out-of-PATH scripts for
  candidate packages, but this is an inventory of observed paths, not a complete census.
- **B. Package mapping**: sweep A through `xargs dpkg -S | cut -d: -f1 | sort | uniq -c`.
- **C. Reverse-deps**: `apt-cache rdepends --installed` for `python3-apt`, `python3-dbus`,
  `python3-gi`. Used as a candidate generator only; rdepends does not distinguish direct
  from transitive and is not treated as proof of administrative relevance.
- **D. Daemons**: `ExecStart` shebang resolution across `/usr/lib/systemd/system` and
  `/etc/systemd/system`; `Exec=` resolution in `/usr/share/dbus-1/system-services/`.
  Misses generated units, drop-ins, and wrapper indirection; observed paths only.
- **E. Out-of-PATH scripts**: `dpkg -L <pkg>` + executable shebang check per candidate
  package.

Per-record deep dives: `head -1` (shebang), `grep '^import\|^from'` (direct imports),
`dpkg -s` (Depends), `/usr/share/polkit-1/actions/` (privilege), `systemctl` unit and
timer state ("installed and active" vs merely installed), `apt-cache policy` (component).

### Inclusion rubric

Include a tool when all three hold:

1. **Shipped by Ubuntu/Debian** — record archive component, source package, and maintainer
   separately; `main` is not treated as synonymous with first-party, and Ubuntu-originated
   `universe` packages remain eligible.
2. **Implemented in Python** — the capability's entry point is a Python script or a Python
   package provides the logic. "Python implementation" is recorded separately from
   "Python dependency" (a non-Python wrapper over a Python backend counts; a Python
   wrapper over a C library is noted as such).
3. **Administers the system** — mutates packages, repositories, configuration, hardware,
   services, or users; or reports system state to an administrator.

Exclusions (recorded in Appendix A): Python-library CLI stubs, dev tooling, third-party
applications, desktop end-user applications. `bpfcc-tools` (105 scripts) collapses to one
diagnostics row.

### Canonical record template

Each full record uses exactly these fields:

> Program · Ubuntu package (version, component, source, maintainer) · Installed/active ·
> Category · Implementation (language + entry point) · Daemon vs command · Python
> dependencies (direct) · Native APIs underneath · IPC/API used · Privilege model ·
> Boot-critical? · Performance-sensitive? · Cross-distro equivalents (knowledge-based) ·
> KDE prior art (knowledge-based) · Candidate Runix APIs · Replacement difficulty ·
> Replacement value · Technically bounded? · Evidence

## Summary

17 full records, 8 table-only rows. Headline findings:

1. **The Python footprint is concentrated in the apt/update ecosystem.** 10 of 17 full
   records sit on python3-apt. Service management (systemctl: C), users/groups (adduser:
   Perl; accounts-daemon: C), udev, storage, and session management have **zero Python**.
   Runix Phase 2's apt+systemd slice covers the Python-heavy half and the native half in
   one stroke.
2. **The privilege pattern Runix needs already ships in 4 root Python D-Bus backends**:
   aptd (13 polkit actions), software-properties-dbus, ls-dbus-backend, and
   usb-creator-helper — all D-Bus-activated as root, all gating each method through
   polkit `CheckAuthorization`. These are simultaneously prior art and replacement targets.
3. **Canonical already migrates hot paths to C and leaves policy in Python**: netplan
   (C libnetplan1 + C boot generator, Python CLI), ubuntu-drivers-common (C gpu-manager
   on the display-manager boot path, Python CLI), ubuntu-pro-client (C apt hook on the
   `apt upgrade` hot path, 32,700 lines of Python everywhere else). Runix replaces the
   policy layer; the C cores stay.
4. **aptdaemon is largely vestigial on 24.04.** Only language-selector-gnome and
   update-notifier still use it; PackageKit 1.2.8 runs in parallel with its own C apt
   backend (`libpk_backend_apt.so`), which is what GNOME Software and Discover use.
5. **Boot-critical Python is rare.** cloud-init only — and it resolved to DataSourceNone
   and is disabled on this box. netplan's boot half is already C.
6. **Two persistent root Python daemons observed**: unattended-upgrade-shutdown (resident
   logind-inhibitor waiter, running now) and networkd-dispatcher (condition-skipped here;
   `systemd-analyze security` rates it 9.6 UNSAFE).

### Master table

Full records (17):

| Program | Package | Category | Impl | Form | Privilege | Boot-crit | Perf-sens | Difficulty | Value |
|---|---|---|---|---|---|---|---|---|---|
| add-apt-repository, s-p-dbus | software-properties-common 0.99.49.4 | repositories | Python | cmd + D-Bus backend | polkit + root backend | no | no | medium | high |
| aptd, aptdcon | aptdaemon 1.1.1+bzr982 | package mgmt | Python | D-Bus daemon | polkit (13 actions) | no | no | high | low (vestigial) |
| command-not-found | command-not-found 23.04.0 | package mgmt | Python | shell hook | root via apt hook | no | mild | low | low-medium |
| ubuntu-security-status, hwe-support-status | update-manager-core 1:24.04.12 | updates | Python | cmd, read-only | unprivileged | no | no | low-medium | medium |
| unattended-upgrade (+shutdown) | unattended-upgrades 2.9.1 | updates | Python | timer cmd + resident inhibitor | root, no polkit | shutdown-path | no | medium-high | moderate |
| update-manager | update-manager 1:24.04.12 | updates, desktop | Python/GTK | GUI cmd | delegates to aptd+polkit | no | mild | high | moderate |
| apt-check, package-data-downloader | update-notifier-common 3.192.68.2 | updates | Python | apt-hook cmds | root | login-path | yes (apt hot path) | low-moderate | high |
| do-release-upgrade | ubuntu-release-upgrader-core 1:24.04.28 | updates | Python | cmd, long-running | root (pkexec/sudo) | no; bricks on failure | no | high | low-moderate |
| apport suite | apport 2.28.2 | crash reporting | Python (+C whoopsie) | kernel-invoked oneshot | root, unconfined | no | crash-time | high | low-moderate |
| ubuntu-drivers (+C gpu-manager) | ubuntu-drivers-common 1:0.9.7.6 | drivers | Python + C | cmd + C boot oneshot | euid check, root | C half yes | mild | medium-high | medium-high (query) |
| pro (+C apt hook) | ubuntu-pro-client 37.2 | security, updates | Python + C | cmd + timers | root; AppArmor-confined units | no | apt hook (already C) | high / blocked | low-moderate |
| cloud-init | cloud-init 26.1 | cloud provisioning | Python | 4 boot oneshots | root at boot | **yes** | boot latency | very high | low |
| netplan CLI | netplan.io 1.1.2 | networking | Python CLI over C core | cmd (+C generator, C dbus) | root, structural | C half only | mild | low-moderate | **very high** |
| ufw | ufw 0.36.2-6 | security, networking | Python | cmd + boot oneshot | root only | security-critical at boot | no | medium | medium-high |
| networkd-dispatcher | networkd-dispatcher 2.2.4 | networking | Python | persistent daemon | root, unhardened | no | no | low-moderate (native) | moderate |
| check-language-support, ls-dbus-backend | language-selector-common 0.225 | desktop admin | Python | cmd + D-Bus backend | polkit + root backend | no | no | low-moderate | moderate |
| usb-creator-helper | usb-creator-common 0.3.17 | desktop admin, hardware | Python | D-Bus backend | polkit + root, UDisks2 | no | write throughput | moderate | high |

Table-only (8) — observed in sweeps, excluded from full records for scope reasons:

| Program | Package | Category | Note |
|---|---|---|---|
| 105 BCC tracing scripts | bpfcc-tools 0.29.1 | diagnostics | native successors exist: bpftrace (C++), libbpf-tools (C) |
| mountstats, nfsiostat, nfsdclnts | nfs-common, nfs-kernel-server | diagnostics | read-only /proc parsers |
| ssh-import-id | ssh-import-id 5.11 | cloud provisioning | fetches SSH keys from Launchpad/GitHub; bounded |
| ec2metadata | cloud-guest-utils | cloud provisioning | IMDS query CLI |
| switcherooctl | switcheroo-control | hardware | Python client to a C D-Bus daemon |
| powerprofilesctl | power-profiles-daemon | hardware, power | Python client to a C D-Bus daemon |
| prime-select | nvidia-prime | drivers | GPU switch tool |
| hp-pkservice (+hplip suite) | hplip 3.23.12 | hardware, printing | HP upstream; root D-Bus service com.hp.hplip |

## Inventory by category

### Repositories

#### software-properties (add-apt-repository)

- **Program**: `add-apt-repository` (alias `apt-add-repository`), `software-properties-gtk`,
  `software-properties-dbus`
- **Ubuntu package**: software-properties-common 0.99.49.4 (noble-updates/main, source:
  software-properties, maint: Michael Vogt); software-properties-gtk same version
- **Installed/active**: installed; D-Bus backend activates on demand (not resident)
- **Category**: repositories
- **Implementation**: Python 3. Entry points `/usr/bin/add-apt-repository`
  (`#!/usr/bin/python3`), `/usr/lib/software-properties/software-properties-dbus`
  (`#!/usr/bin/env python3`)
- **Daemon vs command**: CLI command + on-demand root D-Bus backend
- **Python dependencies (direct)**: `python3-software-properties` (softwareproperties.*),
  `apt_pkg` (python3-apt), `python3-dbus`, `python3-gi` (GLib main loop)
- **Native APIs underneath**: libapt-pkg (via python3-apt); D-Bus; polkit. Notably
  hard-Depends on **packagekit** + gir1.2-packagekitglib (GUI driver install path)
- **IPC/API used**: system bus name `com.ubuntu.SoftwareProperties`
  (`/usr/share/dbus-1/system-services/com.ubuntu.SoftwareProperties.service`)
- **Privilege model**: unprivileged frontend → root Python D-Bus backend gated by polkit
  actions in `com.ubuntu.softwareproperties.policy` (e.g. `...applychanges` "To change
  software repository settings, you need to authenticate"). CLI run as root writes
  directly.
- **Boot-critical?**: no
- **Performance-sensitive?**: no
- **Cross-distro** *(knowledge-based)*: Debian ships the same package; Fedora:
  `dnf config-manager` (dnf5 is C++, dnf4 was Python); NixOS: declarative config, no
  imperative repo tool; Arch: manual `pacman.conf`
- **KDE prior art** *(knowledge-based)*: Kubuntu's `software-properties-qt` is the **same
  Python backend** with a Qt frontend — KDE has no native reimplementation; Discover
  only toggles repos via PackageKit's RepoEnable
- **Candidate Runix APIs**: `apt_repos()` (deb822 + one-line parse), `apt_repo_add()`
  (incl. `ppa:` resolution), `apt_repo_remove()`, keyring management under
  `/etc/apt/keyrings`
- **Replacement difficulty**: medium — sources.list/deb822 writing is bounded; `ppa:`
  shortcut resolution needs the Launchpad API + GPG key fetch; GUI parity needs the
  polkit/D-Bus split
- **Replacement value**: high — daily-use admin surface, and the D-Bus backend is the
  cleanest model of the privilege pattern Runix must handle
- **Technically bounded?**: mostly; Launchpad/key-fetch is the unbounded edge
- **Evidence**: `head -1`, import grep, `dpkg -s software-properties-common`,
  `com.ubuntu.softwareproperties.policy`, sweep D D-Bus hit (2026-08-07)

### Package management

#### aptdaemon (aptd)

- **Program**: aptd — D-Bus system daemon exposing transactional APT operations (install/remove/upgrade/update-cache/install-file/repo+config edits) to unprivileged desktop clients; `aptdcon` is its CLI client.
- **Ubuntu package**: aptdaemon 1.1.1+bzr982-0ubuntu44 (noble/main, section admin, source aptdaemon, Ubuntu Developers); library split out as python3-aptdaemon (same version)
- **Installed/active**: Installed, not running. `busctl --system list` shows `org.debian.apt` as `(activatable)` with no current owner; no aptd process. No systemd unit — activation is purely D-Bus.
- **Category**: package management
- **Implementation**: Python 3. Entry points `/usr/sbin/aptd` and `/usr/bin/aptdcon`, both `#!/usr/bin/python3`, both thin stubs; all logic in `/usr/lib/python3/dist-packages/aptdaemon/` (core.py, client.py, worker/aptworker.py, policykit1.py, debconf.py, lock.py).
- **Daemon vs command**: Both. `aptd` is a D-Bus-activated root daemon with idle-exit; `aptdcon` a short-lived client. Third-party GUIs use `aptdaemon.client.AptClient` as a library.
- **Python dependencies (direct)**: `apt`, `apt_pkg`, `aptsources` (python3-apt); `dbus` + `dbus.mainloop.glib` (python3-dbus); `gi.repository.GObject/GLib` + `PackageKitGlib` (network-state detection only); `defer` (python3-defer). Depends adds policykit-1, gir1.2-packagekitglib-1.0, iso-codes.
- **Native APIs underneath**: libapt-pkg via python3-apt C++ bindings (full resolver, cache, dpkg invocation), GLib main loop, dpkg lock semantics (`lock.py`), debconf passthrough over a pty, euid/egid drop for downloads.
- **IPC/API used**: D-Bus system bus, name `org.debian.apt`, object `/org/debian/apt`, per-transaction objects `/org/debian/apt/transaction/<uuid>` with progress/finished signals. Activation file `User=root`. Calls out to `org.freedesktop.PolicyKit1`.
- **Privilege model**: root daemon; per-operation polkit `CheckAuthorization` against 13 fine-grained actions in `org.debian.apt.policy` (`install-or-remove-packages`, `upgrade-packages`, `update-cache`, `change-repository`, `change-config`, `high-trust-repo`, ...), mostly `auth_admin`/`auth_admin_keep`. The granular action split is the design's main advance over "sudo apt".
- **Boot-critical?**: no — purely on-demand
- **Performance-sensitive?**: no — transactions dominated by download and dpkg; Python cost only at daemon startup and progress-signal churn
- **Cross-distro** *(knowledge-based)*: Fedora/RHEL: PackageKit (`packagekitd`, C, dnf backend) + dnf5daemon-server; Debian: same aptdaemon package upstream; Arch: PackageKit alpm backend, rarely used; NixOS: no privileged package D-Bus service (nix-daemon plays a different role)
- **KDE prior art** *(knowledge-based)*: Discover uses PackageKit-Qt, not aptdaemon; the retired Muon/QApt `qaptworker` (C++/Qt + polkit) was the closest KDE analogue. KDE's answer to "aptd in Python" is already "PackageKit-Qt in C++".
- **Candidate Runix APIs**: transactional package service (`search/resolve/install/remove/upgrade`, Transaction object with simulate/commit/cancel + typed progress events), repo/config management, fine-grained authorization check, debconf-style prompt channel
- **Replacement difficulty**: high — thin Python veneer over libapt-pkg's resolver, dpkg-lock semantics, debconf-over-pty, and a stable public D-Bus API external GUIs link against
- **Replacement value**: low — **largely vestigial on 24.04**: `apt-cache rdepends --installed` shows only language-selector-gnome and update-notifier's `backend_helper.py` as consumers, while PackageKit 1.2.8 is installed with its own native apt backend (`libpk_backend_apt.so`) that does not proxy through aptd. The reusable ideas (polkit-gated transaction daemon, idle-exit lifecycle: 60s check interval, 10min timeout, per-transaction 300s/30s timers) matter more than the code.
- **Technically bounded?**: yes for the daemon shell (D-Bus surface, polkit gate, queue, idle-exit); no for the payload — correctness is defined by libapt-pkg, so a replacement must keep calling it
- **Evidence**: `head`/`cat` + import grep on both entry points and core.py/console.py/aptworker.py/policykit1.py; `dpkg -s aptdaemon python3-aptdaemon`; `org.debian.apt.policy` action ids; `org.debian.apt.service`; `apt-cache rdepends --installed aptdaemon python3-aptdaemon`; `busctl --system list --activatable`; `ls /usr/lib/x86_64-linux-gnu/packagekit-backend/`; core.py idle-exit at lines 2115-2140; `grep -rn aptdaemon` in LanguageSelector/ and update-notifier/ (2026-08-07)

#### command-not-found

- **Program**: `command-not-found` (shell hook), `cnf-update-db`
- **Ubuntu package**: command-not-found 23.04.0 (noble/main, source: command-not-found,
  maint: Michael Vogt)
- **Installed/active**: installed; hook fires on shell command-miss; DB refreshed by apt
  Post-Invoke hook (`/var/lib/command-not-found/commands.db`, 3.9 MB SQLite, current)
- **Category**: package management (discovery)
- **Implementation**: Python 3. Entry points `/usr/lib/command-not-found`,
  `/usr/lib/cnf-update-db` (both `#!/usr/bin/python3`)
- **Daemon vs command**: command (shell-hook invoked); no daemon
- **Python dependencies (direct)**: `python3-commandnotfound` (CommandNotFound.*),
  `apt_pkg` (python3-apt) in cnf-update-db
- **Native APIs underneath**: SQLite database; apt Commands-* index files fetched via
  `Acquire::IndexTargets` (`/etc/apt/apt.conf.d/50command-not-found`)
- **IPC/API used**: none (stdin/stdout with shell integration)
- **Privilege model**: unprivileged lookup; DB rebuild runs as root only because apt's
  Post-Invoke runs as root — writes `/var/lib/command-not-found/`
- **Boot-critical?**: no; failure is harmless
- **Performance-sensitive?**: mildly — runs on every missed command; startup latency is
  user-visible (relevant to R's startup-cost question)
- **Cross-distro** *(knowledge-based)*: Fedora: `PackageKit-command-not-found` (C);
  Arch: `pkgfile` (C); NixOS: `command-not-found` over channel-generated
  `programs.sqlite`; Debian: same package
- **KDE prior art** *(knowledge-based)*: n/a — shell-level capability, no desktop analogue
- **Candidate Runix APIs**: `apt_command_search("cmd")` over the Commands metadata /
  SQLite index
- **Replacement difficulty**: low — bounded formats (SQLite schema + deb822 Commands
  files), two native precedents to crib from
- **Replacement value**: low-medium — good bounded proof of concept, but per codex
  review it exercises almost none of the privileged-administration architecture
- **Technically bounded?**: yes
- **Evidence**: `head -1`, import grep, `dpkg -s command-not-found`,
  `ls /var/lib/command-not-found/`, `50command-not-found` apt hook (2026-08-07)

### Updates

#### ubuntu-security-status / hwe-support-status

- **Program**: `ubuntu-security-status`, `hwe-support-status`
- **Ubuntu package**: update-manager-core 1:24.04.12 (noble-updates/main, source:
  update-manager, maint: Ubuntu Developers)
- **Installed/active**: installed; run on demand
- **Category**: updates / security reporting
- **Implementation**: Python 3. Entry points `/usr/bin/ubuntu-security-status`,
  `/usr/bin/hwe-support-status` (both `#!/usr/bin/python3`)
- **Daemon vs command**: command, read-only
- **Python dependencies (direct)**: `apt` (python3-apt high-level), `distro_info`,
  `UpdateManager.Core.utils` (python3-update-manager); package Depends adds
  ubuntu-pro-client + ubuntu-release-upgrader-core
- **Native APIs underneath**: libapt-pkg cache and package origins (archive/pocket
  classification: main vs universe vs ESM)
- **IPC/API used**: none; reads apt state, prints report (has `--format json` via
  argparse/json import)
- **Privilege model**: fully unprivileged
- **Boot-critical?**: no
- **Performance-sensitive?**: no
- **Cross-distro** *(knowledge-based)*: Fedora: `dnf updateinfo` (built into dnf);
  Debian: `debsecan` (also Python); Arch: `arch-audit` (Rust); NixOS: `vulnix`
  (third-party)
- **KDE prior art** *(knowledge-based)*: Discover surfaces per-update security
  classification via PackageKit `update-details` (`PK_INFO_ENUM_SECURITY`) — the data
  model, not a reimplementation
- **Candidate Runix APIs**: `apt_security_status()` returning a data frame (package,
  origin, pocket, ESM coverage, support horizon) — pure Phase 1 introspection
- **Replacement difficulty**: low-medium — read-only over apt cache + origin metadata;
  ESM/Pro coverage needs the Pro contract data the tool currently gets via
  ubuntu-pro-client
- **Replacement value**: medium — admins read this output; perfect introspection-first
  fit
- **Technically bounded?**: yes
- **Evidence**: `head -1`, import grep, `dpkg -s update-manager-core`, sweep E hits
  (2026-08-07)

#### unattended-upgrades

- **Program**: `/usr/bin/unattended-upgrade` (2522-line Python script); helper `/usr/share/unattended-upgrades/unattended-upgrade-shutdown` (414 lines); alias `/usr/bin/unattended-upgrades`
- **Ubuntu package**: unattended-upgrades 2.9.1+nmu4ubuntu1 (noble/main, source unattended-upgrades, orig. maint Michael Vogt)
- **Installed/active**: installed; `unattended-upgrades.service` enabled + **active** (PID 2091 is the shutdown helper resident in `--wait-for-signal` mode); apt-daily.timer and apt-daily-upgrade.timer enabled + active; logs in `/var/log/unattended-upgrades/`
- **Category**: updates
- **Implementation**: pure Python 3; heavy lifting delegated to python3-apt over libapt-pkg
- **Daemon vs command**: both. The upgrade run is a one-shot fired from the timer chain (`apt-daily-upgrade.timer` → `apt.systemd.daily install` (shell) → `unattended-upgrade` at line 495). Separately, `unattended-upgrades.service` is a long-lived Python process holding a logind delay-inhibitor to finish upgrades before shutdown.
- **Python dependencies (direct)**: `apt`, `apt_pkg`, `apt_inst`, `distro_info`, optional `gi.repository.Gio.NetworkMonitor`; shutdown helper adds `dbus` + `dbus.mainloop.glib` + GLib. Depends: debconf, python3-apt, python3-dbus, python3-distro-info, ucf, lsb-release, xz-utils
- **Native APIs underneath**: libapt-pkg (`apt_pkg.config`, `apt.Cache`, `apt_pkg.pkgsystem_lock_inner()`), dpkg subprocess with `DPkg::Options`, GIO metered-network check, fcntl locking, syslog
- **IPC/API used**: D-Bus to `org.freedesktop.login1` — `Manager.Inhibit` (delay lock), reads `InhibitDelayMaxUSec`, subscribes to `PrepareForShutdown`; ships a logind drop-in raising `InhibitDelayMaxSec=30`. Hooks in `/etc/kernel/postinst.d/`, systemd-sleep, MOTD fragment `92-unattended-upgrades`.
- **Privilege model**: root, unconditionally. No polkit, no sandboxing directives on the units (`KillMode=process`, `TimeoutStopSec=1800` only). Full package-installation authority.
- **Boot-critical?**: no for boot; **shutdown-path-relevant** — a misbehaving replacement can stall shutdown up to 30 min
- **Performance-sensitive?**: no — 06:00 with 60m random delay; resident helper ~8 MB RSS, 38 ms CPU over 10 days
- **Cross-distro** *(knowledge-based)*: Fedora `dnf-automatic` is likewise Python; NixOS `system.autoUpgrade` (declarative); openSUSE zypper-automatic/YaST. The pattern is universal, the Python is incidental to the apt/dnf bindings.
- **KDE prior art** *(knowledge-based)*: Discover prefers PackageKit offline updates (staged, applied at reboot) — architecturally the opposite of live in-place apply; the C++/D-Bus precedent for "keep the box patched" exists
- **Candidate Runix APIs**: package transaction with origin/allowlist filtering; system-lock acquisition; logind inhibitor lease + `PrepareForShutdown` subscription; network state (online/metered); AC-power state; reboot-required signalling
- **Replacement difficulty**: medium-high — the core loop is bounded, but the tail is long: dry-run/chroot modes, `MinimalSteps` unlock/relock dance, dpkg journal recovery, mail reporting, needrestart, exact apt-config parity
- **Replacement value**: moderate — high visibility and a genuine win removing Python from the shutdown-inhibitor path, but the real work already lives in libapt-pkg; a rewrite mostly re-expresses policy
- **Technically bounded?**: partly — the happy path yes; correctness lives in the failure modes (interrupted dpkg, shutdown races, ESM origin matching), exactly where damage occurs
- **Phase 4 fit**: **excluded** per PLAN.md — unattended root mutation of the security posture with no operator present, plus the shutdown-stall hazard
- **Evidence**: `dpkg -s`; shebangs + import greps on both scripts; `systemctl cat unattended-upgrades.service apt-daily{,-upgrade}.timer`; `grep -n unattended /usr/lib/apt/apt.systemd.daily` (lines 479-502); `/etc/apt/apt.conf.d/{20auto-upgrades,50unattended-upgrades}`; logind drop-in (2026-08-07)

#### update-manager

- **Program**: `/usr/bin/update-manager` — "Software Updater", the GTK updater dialog
- **Ubuntu package**: update-manager 1:24.04.12 (noble-updates/main, section gnome, source update-manager) + update-manager-core; library python3-update-manager
- **Installed/active**: installed; a session instance was running at survey time (`--no-update --no-focus-on-map`); no systemd unit
- **Category**: updates, desktop administration
- **Implementation**: Python 3 + GTK3/libhandy; library in `/usr/lib/python3/dist-packages/UpdateManager/`
- **Daemon vs command**: foreground GUI command; privileged work delegated to the aptdaemon system daemon
- **Python dependencies (direct)**: `gi` (Gtk, Gio, GLib, Handy, Snapd), `dbus`, `apt`/`apt_pkg`, `distro_info`, `uaclient.api` (Ubuntu Pro), `DistUpgrade.DistUpgradeCache`, `aptdaemon.client` + `aptdaemon.gtk3widgets`, `defer`, `yaml`, optional `launchpadlib`
- **Native APIs underneath**: libapt-pkg (cache/depcache/policy); snapd REST socket via Snapd GIR; NetworkManager D-Bus for metered detection; aptd's libapt underneath the transaction
- **IPC/API used**: session D-Bus (single-instance), system D-Bus to `org.debian.apt`, polkit via aptd, snapd UNIX socket, HTTPS to changelogs.ubuntu.com and meta-release
- **Privilege model**: runs unprivileged; escalation fully delegated. Verified in `UpdateManager/backend/__init__.py:418-465`: `get_backend()` picks `InstallBackendAptdaemon` when `/usr/sbin/aptd` exists, falls back to synaptic — synaptic is **not** installed, so **aptdaemon is the only working backend on this box**. PackageKit is installed but unused by update-manager.
- **Boot-critical?**: no
- **Performance-sensitive?**: mildly — full cache open + network fetches make startup multi-second
- **Cross-distro** *(knowledge-based)*: GNOME Software (C, PackageKit/flatpak plugins) on Fedora; the generic layer others standardize on is PackageKit's D-Bus API + offline updates
- **KDE prior art** *(knowledge-based)*: Discover's update page over PackageKit-Qt; on Kubuntu it drives apt through PackageKit's aptcc backend, not aptdaemon. `plasma-pk-updates` did the notifier job before folding into Discover.
- **Candidate Runix APIs**: `packages.list_upgradable()`, `packages.upgrade()` with progress/cancel streaming, `packages.changelog()`, `system.reboot_required()`, `subscription.status()`, `network.is_metered()`
- **Replacement difficulty**: high — the Python is a shell, but parity needs apt resolution, phased-update filtering, ESM display, HWE status, release-upgrade handoff, snap refresh, a GUI, and a privileged transaction service
- **Replacement value**: moderate — user-facing, runs only when opened; value concentrates in the transaction/authorization layer it borrows from aptdaemon
- **Technically bounded?**: partly — the UI layer yes; the transitive surface (aptdaemon, DistUpgrade, uaclient, snapd, meta-release) pulls in most of the update stack
- **Evidence**: shebang + import greps; `dpkg -s update-manager` (Depends: `python3-aptdaemon.gtk3widgets ... | synaptic`, pkexec, polkitd); `backend/__init__.py:418-465`; `dpkg -l` synaptic absent, aptdaemon present; live process list (2026-08-07)

#### update-notifier (apt-check)

- **Program**: `/usr/lib/update-notifier/apt-check` — computes upgradable/security/ESM counts and feeds the MOTD "N updates" block; `/usr/lib/update-notifier/package-data-downloader` fetches deferred package data. (The tray daemon `/usr/bin/update-notifier` is C — not part of this record.)
- **Ubuntu package**: update-notifier-common 3.192.68.2 (noble-updates/main, section gnome, source update-notifier, maint Michael Vogt)
- **Installed/active**: installed; `update-notifier-download.timer` enabled+active (24h), `motd-news.timer` enabled+active; live output `/var/lib/update-notifier/updates-available` current ("14 updates ... 59 additional security updates with ESM Apps")
- **Category**: updates
- **Implementation**: Python 3, driven by shell glue (`update-motd-updates-available`, `/etc/update-motd.d/90-updates-available`)
- **Daemon vs command**: one-shot commands — apt-hook-invoked (apt-check) and timer-invoked (package-data-downloader). No Python daemon.
- **Python dependencies (direct)**: apt-check: `apt`, `apt_pkg`, `distro_info`, lazy `UpdateManager.Core.UpdateList` for phased-update exclusion; downloader: `debian.deb822`, `debconf`, `apt_pkg`. Depends: python3-apt, python3-dbus, python3-debian, python3-distro-info, update-manager-core
- **Native APIs underneath**: libapt-pkg (origin/archive matching incl. `UbuntuESM`/`UbuntuESMApps`), debconf protocol, dpkg status, the Pro ESM cache at `/var/lib/ubuntu-advantage/apt-esm/`
- **IPC/API used**: file-based. apt hook `/etc/apt/apt.conf.d/99update-notifier` (`DPkg::Post-Invoke` + `APT::Update::Post-Invoke-Success`) → staleness check → `apt-check --human-readable` → atomic `mv` into the stamp file → MOTD `cat`s it at login
- **Privilege model**: root (apt hooks + system timer); apt-check itself is read-only and runs unprivileged for reporting. Ships pkexec actions (`com.ubuntu.update-notifier.policy`) for the GUI side only.
- **Boot-critical?**: no, but on the **login path** (MOTD reads the precomputed file — cheap; the cost is paid during apt runs)
- **Performance-sensitive?**: **yes** — apt-check opens the full apt cache and walks every package on every `apt update` and every dpkg transaction; a known contributor to Ubuntu apt slowness
- **Cross-distro** *(knowledge-based)*: Ubuntu-specific. Debian has no MOTD update counter; Fedora uses dnf-makecache + insights banners; Arch `checkupdates`. The ESM upsell portion is unique to Ubuntu.
- **KDE prior art** *(knowledge-based)*: Discover polls PackageKit (`GetUpdates` + `UpdatesChanged` signals) — the count comes from a daemon's cached state over D-Bus rather than a per-apt-run subprocess writing a text file; strictly cheaper for the same information
- **Candidate Runix APIs**: `packages.update_counts()` (total/security/phased-held, cached), `packages.cache_stale()`, MOTD fragment registration with staleness handling, `packages.hooks.on_transaction_complete()`
- **Replacement difficulty**: low-to-moderate for apt-check — a single self-contained script whose logic is "walk the depcache, classify by origin, pluralize"; the downloader is harder in proportion to its debconf surface
- **Replacement value**: **high** — root, on the apt hot path, runs on every transaction, output contract is one text file; a native implementation removes an interpreter start + full cache walk from every apt operation
- **Technically bounded?**: yes for apt-check (inputs and the one-file output are fully enumerable); less so for package-data-downloader (executes per-package hook scripts)
- **Evidence**: shebangs + import greps (lazy import at apt-check:452); `dpkg -s update-notifier-common`; `update-motd-updates-available:62`; `99update-notifier` hooks; live stamp file contents; timer states (2026-08-07)

#### ubuntu-release-upgrader (do-release-upgrade)

- **Program**: `do-release-upgrade` — release-to-release upgrade driver; `check-new-release` (argv[0]-dispatched symlink), `do-partial-upgrade`, MOTD hook
- **Ubuntu package**: ubuntu-release-upgrader-core 1:24.04.28 (noble-updates/main, source ubuntu-release-upgrader); logic in python3-distupgrade; GTK frontend also installed
- **Installed/active**: installed and wired (`Prompt=lts`, MOTD stamp current, meta-release cache fresh); a real upgrade ran on this box 2026-05-05 (`/var/log/dist-upgrade/`). No dedicated timer — piggybacks on MOTD machinery.
- **Category**: updates
- **Implementation**: Python 3; `/usr/lib/python3/dist-packages/DistUpgrade/` — 29 modules, **~14,200 lines**, with Text/GTK3/KDE/NonInteractive view classes. Zero compiled code.
- **Daemon vs command**: one-shot interactive command, long-running (minutes to hours)
- **Python dependencies (direct)**: `DistUpgrade.*`, `UpdateManager.Core.MetaRelease`, `apt`, `apt_pkg`, `aptsources`, `dbus`, `gi.repository.{Gio,GLib}`, `distro_info`. Depends: python3-distupgrade → python3-apt, python3-dbus, python3-update-manager, gpgv, procps
- **Native APIs underneath**: libapt-pkg (`apt_pkg.Acquire` for downloads, `TagFile` for meta-release parsing, config tuning incl. `--force-overwrite`), aptsources rewriting, dpkg/apt as the engine, logind sleep inhibitor via GIO fd-passing, `apt-key`/gpgv verification, shell-outs to screen/sudo/pkexec/sshd/snap/systemctl
- **IPC/API used**: HTTPS to `changelogs.ubuntu.com/meta-release-lts` (If-Modified-Since cached); the meta-release index yields `UpgradeTool`/`UpgradeToolSignature` URLs — **the tool downloads a signed tarball and `os.execv`s the extracted `dist-upgrade.py`, so the code that actually performs the upgrade is fetched at runtime, not the code on disk**. D-Bus: logind `Inhibit("shutdown:sleep")`, session ScreenSaver inhibit.
- **Privilege model**: root required; GUI path re-execs via pkexec (`com.ubuntu.release-upgrader.policy`), CLI via `sudo -E`. Session-survival machinery: re-exec inside GNU screen when needed, spare sshd on port 1022 for SSH upgrades. **Only screen is supported, and screen is not installed here (tmux only) — that safety net silently no-ops on this machine.**
- **Boot-critical?**: no — but the highest-blast-radius tool in this survey: rewrites all apt sources then dist-upgrades the running system; mid-run failure routinely leaves an unbootable mixed-release box. The screen/sshd/inhibitor/btrfs-snapshot machinery exists precisely because of that.
- **Performance-sensitive?**: no — dominated by download and dpkg. Only `check-new-release -q` on the MOTD path is latency-relevant, hence backgrounded + 24h stamp.
- **Cross-distro** *(knowledge-based)*: Fedora `dnf system-upgrade` is also Python (staged offline, safer shape); openSUSE `zypper dup` is C++ on libzypp; Arch rolling; Debian's documented path is manual sources editing + `apt full-upgrade`. Ubuntu is the outlier in bespoke Python policy (quirks, deb→snap migration, demotion lists).
- **KDE prior art** *(knowledge-based)*: Kubuntu ships `DistUpgradeViewKDE.py` in this very package (PyQt5) — a frontend veneer. PackageKit exposes `UpgradeSystem()`/`GetDistroUpgrades()` but delegates the actual hop to the distro. No reimplementation prior art.
- **Candidate Runix APIs**: meta-release fetch/parse; signed-artifact verification; sources.list suite rewriting; session-detachment primitive (screen/tmux/systemd-run scope) for long privileged operations; logind inhibition with fd lifetime; snapshot-before-upgrade
- **Replacement difficulty**: high — `DistUpgradeQuirks.py` alone is 2,143 lines of per-release institutional knowledge with no spec, and the on-disk code is mostly a bootstrapper for the runtime-downloaded tarball. Correctness bar: bugs brick machines.
- **Replacement value**: low-to-moderate — runs once per machine every 6-24 months; the genuine wins (session detachment that actually works — see the dead screen fallback here — snapshots, resumable transactions) are better delivered as Runix primitives the existing tool could adopt
- **Technically bounded?**: no — the quirks corpus grows every release and effective behavior is not determined by anything on this disk. Bounded extractable sub-pieces: meta-release parsing, signature verification, sources rewriting, session detachment, inhibition.
- **Evidence**: `dpkg -s` on all three packages; shebangs/imports; `wc -l DistUpgrade/*.py` (14,218); `DistUpgradeFetcherCore.py:95-145` (verify+extract), `:211-256` (sudo re-exec); `DistUpgradeMain.py:164-220` (screen re-exec); `DistUpgradeController.py:320-359` (port-1022 sshd), `:1777-1841` (btrfs snapshot); `MetaRelease.py:349-364`; `/etc/update-manager/{meta-release,release-upgrades}`; `/var/log/dist-upgrade/` dates; `which screen tmux` (2026-08-07)

### Drivers

#### ubuntu-drivers-common

- **Program**: `ubuntu-drivers` (list/devices/install/autoinstall), `nvidia-detector`, `quirks-handler`, and the **C** `gpu-manager`
- **Ubuntu package**: ubuntu-drivers-common 1:0.9.7.6ubuntu3.7 (noble-updates/main, source same, Ubuntu Developers)
- **Installed/active**: installed; `gpu-manager.service` enabled, ran at boot (oneshot, 65 ms), now dead. CLI on-demand.
- **Category**: drivers
- **Implementation**: **mixed C + Python** — the key finding. Python: `/usr/bin/ubuntu-drivers` (553 lines, click-based) + `UbuntuDrivers/detect.py` (1,704) + NvidiaDetector (~600) ≈ 3,000 lines. C: `/usr/bin/gpu-manager`, 80 KB stripped ELF linking **libpci, libdrm, libkmod, libudev**. Shell helper `u-d-c-print-pci-ids`.
- **Daemon vs command**: Python side pure CLI; C gpu-manager is a boot oneshot ordered `Before=display-manager.service`, plus udev rules stamping `/run/u-d-c-*` flag files on DRM/nvidia module events
- **Python dependencies (direct)**: `apt_pkg`, `click`, `xkit` (xorg.conf editing); subprocess to `modinfo`, `udevadm hwdb`, `apt-get`
- **Native APIs underneath**: sysfs walk of `/sys/devices/**/modalias`; apt package-record `Modaliases:` headers parsed into a bus→alias→package map; kmod; libpci/libdrm/libkmod/libudev in the C half
- **IPC/API used**: no D-Bus, no polkit — subprocess + apt cache + `/run` flag files. The Python API (`import UbuntuDrivers.detect`) is a first-class documented interface.
- **Privilege model**: explicit euid check (`ubuntu-drivers:422` "must be run as root"), then root `apt-get install`. Query subcommands unprivileged. gpu-manager root at boot.
- **Boot-critical?**: partially — **the C half gates display-manager**; the Python half is not on any boot path
- **Performance-sensitive?**: mildly — full sysfs walk + all-package Modaliases scan makes `list` take seconds (memoized); the boot-path piece is C for exactly this reason
- **Cross-distro** *(knowledge-based)*: largely Ubuntu-unique (apt Modaliases headers, DKMS/OEM metapackage conventions). Debian's `isenkram` borrows the modalias idea; Fedora relies on RPM Fusion with no auto-candidacy tool.
- **KDE prior art** *(knowledge-based)*: weak — this package `Provides:` the dead `jockey-kde`; modern KDE has no driver-installation module (kinfocenter only reports)
- **Candidate Runix APIs**: modalias enumeration as a data frame (device, sysfs path, bus, IDs, bound module); driver candidacy as a joinable data frame (device × package × free/nonfree × recommended × installed); apt Modaliases index reader; install action with dry-run plan
- **Replacement difficulty**: medium-high for parity, low-medium for the useful part — detection/candidacy is well-factored Python over apt_pkg + sysfs; the NVIDIA version-ordering policy and the C boot component are the hard/untouchable parts
- **Replacement value**: medium-high for querying (today's only interfaces: unstructured CLI text or undocumented Python API); low for installing (thin apt-get shell-out)
- **Technically bounded?**: yes for the query layer; no for the whole package (C gpu-manager + open-ended NVIDIA quirks)
- **Evidence**: `dpkg -L | grep bin`; `file` + `ldd /usr/bin/gpu-manager`; `gpu-manager.service`; udev rules `71-u-d-c-gpu-detection.rules`; shebang/imports; `grep -n modalias detect.py` (62 hits); `grep -n geteuid /usr/bin/ubuntu-drivers`; `wc -l` (2026-08-07)

### Networking

#### netplan (CLI)

- **Program**: `/usr/sbin/netplan` → `/usr/share/netplan/netplan.script` (23-line Python shim: `from netplan_cli import Netplan; Netplan().main()`). Subcommands: apply, generate, get, set, try, status, info, ip, migrate, sriov-rebind.
- **Ubuntu package**: netplan.io 1.1.2-8ubuntu1~24.04.2 (noble-updates/main, priority **important**, source netplan.io). Lockstep siblings from the same source: **libnetplan1** (C), **netplan-generator** (C), **python3-netplan** (cffi bindings).
- **Installed/active**: installed and in use — `/etc/netplan/01-network-manager-all.yaml` sets `renderer: NetworkManager`; renderer output live under `/run/NetworkManager/`. NetworkManager active; systemd-networkd inactive.
- **Category**: networking
- **Implementation**: **Python CLI over a C core — the migration pattern Runix wants, spelled out end to end.** YAML grammar, netdef model, and backend emission live in `libnetplan.so.1` (354 KB, **97 exported `netplan_*` symbols**). Python is ~5,700 lines of argument parsing, subprocess orchestration, and rich formatting, plus ~890 lines of cffi shim. The CLI never parses netplan YAML itself.
- **Daemon vs command**: command; two C companions — `/usr/libexec/netplan/generate` (systemd **system-generator**, runs in early boot) and `netplan-dbus` (D-Bus-activated `io.netplan.Netplan`, root)
- **Python dependencies (direct)**: own cffi bindings (`_netplan_cffi.abi3.so`), `yaml` (auxiliary only), `rich` (status output); stdlib otherwise. No click, no requests, no dbus-python — shells to `busctl` when it needs D-Bus.
- **Native APIs underneath**: libnetplan1 → libyaml, glib/gio, libuuid; generator and netplan-dbus link libsystemd (sd-bus). Kernel effects via `ip`/`networkctl`/`nmcli` subprocesses (11/5/6 call sites).
- **IPC/API used**: D-Bus `io.netplan.Netplan` (system bus, root-owned, `AssumedAppArmorLabel=unconfined`); `netplan try` coordinates rollback via a stamp file
- **Privilege model**: root, enforced structurally (writes to /etc/netplan, /run/systemd/network, /run/NetworkManager) — no euid gate, no polkit
- **Boot-critical?**: **yes — but the boot-critical part is C, not Python.** systemd runs the C generator in early boot; Python is never on the boot path. Canonical packaged them separately precisely so early boot needs no interpreter.
- **Performance-sensitive?**: mildly — generator is C for the boot path; the CLI is interactive
- **Cross-distro** *(knowledge-based)*: Canonical project; exists in Debian but non-default; Fedora/RHEL/Arch configure networkd/NM directly. Ubuntu-shaped blast radius — an advantage for a targeted migration.
- **KDE prior art** *(knowledge-based)*: KDE bypasses netplan entirely — plasma-nm → NetworkManagerQt → NM D-Bus, one layer below. Demonstrates the native-binding instinct but offers no prior art for the netplan layer itself.
- **Candidate Runix APIs**: `netplan_get()/set()/apply()/try()/generate()/status()` over a netdef object model. **An R binding to libnetplan1 would be a native-first Runix package** — linking the same C ABI the Python cffi shim consumes (strong evidence the surface is FFI-friendly). Note: no pkg-config file ships; declare `-lnetplan` directly (libnetplan-dev is in the archive, uninstalled here).
- **Replacement difficulty**: **low-to-moderate — the lowest-risk high-value target in this survey.** None of the hard work is in Python. The fiddly parts: `netplan status` (725 lines) and `netplan try` (termios/signals rollback).
- **Replacement value**: **very high — the key exemplar of "swap the Python CLI, keep the C core".** The seam is already cut and load-bearing in the shipped 4-package design; Runix replaces exactly one of the four. Every other candidate should be measured against how closely it approximates this shape.
- **Technically bounded?**: yes, unusually cleanly — one C ABI (97 symbols, versioned), one D-Bus interface, one YAML schema owned by the C side, 8 external commands. The full behavioral contract is enumerable from installed files.
- **Evidence**: `head -1` + `file /usr/sbin/netplan`; `dpkg -s netplan.io python3-netplan libnetplan1` (lockstep versions); `file` + `ldd /usr/libexec/netplan/generate`; `ls -la /usr/lib/systemd/system-generators/netplan`; `nm -D libnetplan.so.1 | grep ' T '` (97 symbols); D-Bus service + policy files; `/etc/netplan/*.yaml`; renderer state under /run (2026-08-07)

#### networkd-dispatcher

- **Program**: `/usr/bin/networkd-dispatcher` — runs hook scripts on systemd-networkd link-state changes; the networkd analogue of NetworkManager-dispatcher
- **Ubuntu package**: networkd-dispatcher 2.2.4-1 (noble/main, priority important, section utils, orig. maint Julian Andres Klode)
- **Installed/active**: installed; service **enabled but inactive** for two verified reasons: `ConditionPathExistsGlob` unmet (all 12 hook dirs empty) and this box runs NetworkManager, not systemd-networkd
- **Category**: networking
- **Implementation**: pure Python 3, single 547-line script
- **Daemon vs command**: **persistent daemon** — `Type=notify`, GLib main loop, hand-rolled sd_notify over `NOTIFY_SOCKET` (AF_UNIX datagram) rather than libsystemd
- **Python dependencies (direct)**: `dbus` + `dbus.mainloop.glib`, `gi.repository.GLib`; stdlib otherwise. Depends: dbus, python3-dbus, python3-gi.
- **Native APIs underneath**: systemd-networkd D-Bus — subscribes to `PropertiesChanged` on `org.freedesktop.network1.Link` objects, reads `OperationalState`/`AdministrativeState`. **Caveat: also shells out to `networkctl list/status` and regex-parses the text — exactly the CLI-scraping pattern PLAN.md tells Runix to avoid.**
- **IPC/API used**: D-Bus signal subscription (consumer only); sd_notify datagram; `subprocess.Popen` per hook with synthesized environment (IFACE, STATE, ESSID, JSON blob)
- **Privilege model**: root, **unhardened** — no `User=`, full 41-capability bounding set, zero sandbox directives; `systemd-analyze security` scores it **9.6 UNSAFE**
- **Boot-critical?**: no — machine boots and networks fine with it condition-skipped (as now)
- **Performance-sensitive?**: no — rare events; cost is idle RSS of a root Python+dbus+GObject process for the machine's uptime
- **Cross-distro** *(knowledge-based)*: NetworkManager-dispatcher is **C, inside NM itself** — the same problem already has a mature native solution in the NM world; networkd-dispatcher exists only because networkd upstream declines to ship one. All distros package this identical Python script; no native reimplementation exists anywhere.
- **KDE prior art** *(knowledge-based)*: no dispatcher equivalent; the relevant KDE lesson is the binding layer (NetworkManagerQt-style typed D-Bus proxies), not a dispatcher
- **Candidate Runix APIs**: D-Bus signal-subscription primitives; a typed `org.freedesktop.network1` binding (Link objects as structured properties, replacing networkctl scraping); sd_notify; an ordered hook-directory executor with environment injection
- **Replacement difficulty**: low-to-moderate — small logic, stable documented D-Bus API. Per PLAN.md the replacement should be **native (C/Rust), not R** — persistent privileged event-driven daemon is precisely the shape PLAN.md assigns to native code, with R as the client.
- **Replacement value**: moderate — canonical target shape (removes a persistent root Python interpreter and the CLI-scraping), but inert on NM desktops; value concentrates on networkd servers/cloud images
- **Technically bounded?**: yes — single file, one D-Bus interface, one output contract (exec hooks with fixed env). Fuzzy edge: optional ESSID via `iw`/`iwconfig`, replaceable with nl80211 or droppable.
- **Evidence**: `dpkg -s`; shebang/imports (`bus.add_signal_receiver` at 285-288, network1.Link filter at 395, sd_notify at 450); full unit text (two `ConditionPathExistsGlob=|`, zero hardening); `systemctl show -p ConditionResult -p User -p CapabilityBoundingSet`; `systemd-analyze security` 9.6; hook dirs all empty; NM active / networkd inactive (2026-08-07)

### Security

#### ufw

- **Program**: `/usr/sbin/ufw` — "Uncomplicated Firewall" CLI; 159-line driver over `/usr/lib/python3/dist-packages/ufw/` (~216 KB: frontend, parser, backend_iptables, applications)
- **Ubuntu package**: ufw 0.36.2-6 (noble/main, section admin, priority standard, source ufw, maint Jamie Strandboge)
- **Installed/active**: installed; `ufw.service` enabled and "active (exited)" — **but the firewall is off**: `/etc/ufw/ufw.conf` has `ENABLED=no`, and `ufw-init start quiet` exits 0 without loading chains
- **Category**: security, networking
- **Implementation**: Python 3 end to end, stdlib only — no compiled extension, no third-party modules, no dbus, no python-nftables
- **Daemon vs command**: command + boot oneshot (`Type=oneshot`, `RemainAfterExit=yes`, `Before=network-pre.target`, `DefaultDependencies=no`); the kernel does all filtering, ufw only loads rules
- **Python dependencies (direct)**: stdlib only. Depends: iptables, ucf, debconf.
- **Native APIs underneath**: none directly — shells to iptables binaries, which on this box are Debian alternatives pointing at **iptables-nft**: the real kernel path is nf_tables via the compat layer (`lsmod` confirms nft_compat). ufw itself contains **zero** references to nft; it is iptables-syntax-only.
- **IPC/API used**: subprocess only — bulk loads via `cat rules | iptables-restore -n` (`backend_iptables.py:587-595`); enable/disable delegate to the shell `ufw-init`. fcntl lock on `/run/ufw.lock`. No D-Bus, no polkit, no socket.
- **Privilege model**: root-only, setuid-free; rule files 0640 root:root (verified: permission denied as user). Authority is caller's uid 0 + CAP_NET_ADMIN in the iptables children.
- **Boot-critical?**: not for reaching a usable system — **but security-critical at boot**: the oneshot exists to install rules before interfaces come up; if it fails with `ENABLED=yes` the box boots fully open. Low availability risk, high exposure risk.
- **Performance-sensitive?**: no — kernel filters at line rate; Python runs only at rule-edit time and boot, via one batched restore transaction
- **Cross-distro** *(knowledge-based)*: firewalld (Fedora/RHEL/SUSE default) is **also Python** — a D-Bus daemon over python-nftables/libnftables. Arch/Gentoo: raw `nft` or restore scripts. Policy layer is Python across both dominant families; mechanism is C everywhere.
- **KDE prior art** *(knowledge-based)*: **plasma-firewall** KCM has pluggable ufw and firewalld backends; the ufw backend invokes the CLI through a KAuth/polkit helper and screen-scrapes the text output. That KAuth-wrapping-a-CLI seam is exactly what a typed Runix API would replace. Not installed here.
- **Candidate Runix APIs**: typed rule objects (direction/action/proto/port/CIDR/iface/log) replacing the string grammar; non-root-readable status via a privileged read service; transactional apply speaking **nftables netlink directly** with atomic rollback; app profiles; change events so GUIs need not re-parse
- **Replacement difficulty**: medium — clean two-layer split and no daemon/state machine, but the rule grammar is large and accreted (limit, route, app profiles, IPv6 mirroring, the ufw-before/user/after chain topology), and on-disk `/etc/ufw/*.rules` + CLI compatibility must hold or fail2ban/docker-ufw guides/plasma-firewall break
- **Replacement value**: medium-high — native nftables transaction instead of `cat | iptables-nft-restore`, typed API for GUI clients, drops the compat translation layer, removes Python from the `Before=network-pre.target` path. Tempered by: stable, rarely touched, and a wrong rule is a security incident.
- **Technically bounded?**: yes — one CLI (documented), six rule files, one config, one shell shim, one systemd oneshot, one external interface. Scope knowable up front.
- **Evidence**: shebang + imports; `dpkg -s ufw`; `grep -rn nft` in ufw/ (zero hits); `grep -n restore backend_iptables.py` (587-595); `update-alternatives --query iptables` → iptables-nft; `lsmod | grep nf_tables`; unit text; `/etc/ufw/ufw.conf` ENABLED=no; 0640 perms verified as user (2026-08-07)

#### ubuntu-pro-client (pro / ubuntu-advantage)

- **Program**: `pro` (`/usr/bin/ubuntu-advantage`, `ua` symlinks) — Ubuntu Pro entitlement client: attach/detach, ESM/livepatch/FIPS enablement, CVE/USN fixes, security-status, apt/MOTD messaging
- **Ubuntu package**: ubuntu-pro-client 37.2ubuntu~24.04.1 (noble-updates/main, priority important, source ubuntu-advantage-tools)
- **Installed/active**: installed, machine **not attached** (no machine-token; `ua-timer.timer` condition-gated off; apt-news/esm-cache static, apt-triggered)
- **Category**: security, updates
- **Implementation**: Python 3 — `/usr/lib/python3/dist-packages/uaclient/`, **168 files, ~32,700 lines**. Plus one **C++ binary**: `/usr/lib/ubuntu-advantage/apt-esm-json-hook` (51 KB ELF linking libapt-pkg, libjson-c) speaking apt's JSON hook protocol on the `apt upgrade` hot path. (The older `apt-esm-hook` no longer exists in 37.2.)
- **Daemon vs command**: on-demand CLI + oneshot timers (`ua-timer` 6h with 1h jitter); no resident daemon. apt integration: `Pre-Invoke` fires apt-news/esm-cache via `systemctl start --no-block`; the Upgrade hook runs the C++ binary synchronously.
- **Python dependencies (direct)**: `yaml`, `apt`/`apt_pkg`, `pycurl` (proxy edge case); stdlib urllib/json/argparse. Depends: python3-yaml, python3-apt, distro-info + the C-side libapt-pkg/libjson-c.
- **Native APIs underneath**: libapt-pkg (both via python3-apt and directly in the C++ hook), apt sources/preferences/auth files, ESM apt cache under `/var/lib/ubuntu-advantage/apt-esm/`, systemctl subprocesses, cloud metadata services, MOTD, AppArmor profiles for the apt-triggered units
- **IPC/API used**: HTTPS to `contracts.canonical.com` (attach/refresh/metering; server can push polling intervals); `motd.ubuntu.com/aptnews.json`; apt JSON hook protocol (fd handshake); **a stable versioned machine-readable API: `pro api <endpoint>`** with ~30 versioned JSON endpoints (`u.pro.status.is_attached.v1`, `u.pro.security.cves.v1`, ...). No D-Bus service.
- **Privilege model**: root for mutations (`NonRootUserError` gate); no polkit, no privilege separation — `sudo pro`. Read-only commands work unprivileged. apt-news/esm-cache run as root but AppArmor-confined with capability bounding and address-family restrictions.
- **Boot-critical?**: no — all units condition-gated, no-op unattached; failure degrades ESM/messaging only
- **Performance-sensitive?**: one hot path — the apt Upgrade hook, which is **already C++** for exactly that reason (interpreter start + cache load per apt run would be visible)
- **Cross-distro** *(knowledge-based)*: RHEL `subscription-manager` is likewise Python (C rhsm library + D-Bus service); SUSE's suseconnect-ng is Go. Vendor entitlement clients tied to proprietary backends; not portable either way.
- **KDE prior art** *(knowledge-based)*: n/a — no KDE subscription client; Discover surfaces ESM state only indirectly
- **Candidate Runix APIs**: the read-only reporting surface via `pro api` JSON (security status, CVE/USN listing, ESM counts, reboot-required); the versioned JSON-envelope pattern itself is a good model for Runix's machine-readable interface
- **Replacement difficulty**: **high / effectively blocked for the core** — the contract protocol is undocumented, Canonical-proprietary, server-versioned; reimplementing is a compatibility and legal risk. Realistic strategy: **wrap, not replace** — consume `pro api` endpoints, reimplement only presentation/inventory.
- **Replacement value**: low-to-moderate, concentrated in read-only reporting; the entitlement machinery is pure liability to fork
- **Technically bounded?**: no for the package (unbounded external protocol); yes for the scoped subset (consuming `pro api` v1)
- **Evidence**: entry-point shebang; uaclient file/line counts; `defaults.py:53` contract URL; `uaclient.conf`; `file` + `ldd apt-esm-json-hook`; `20apt-esm-hook.conf`; unit files + timer intervals; root gate at `cli_util.py:88`; `pro status`, `pro api u.pro.version.v1` (2026-08-07)

### Crash reporting

#### apport (crash reporting suite)

- **Program**: apport — core-dump handler `/usr/share/apport/apport`, CLI/GTK frontends, uploader `whoopsie-upload-all`, and ~12 hook scripts (package_hook, kernel_oops, recoverable_problem, unkillable_shutdown, ...)
- **Ubuntu package**: apport 2.28.2-0ubuntu0.1 (noble-updates/main, source apport); companions python3-apport, python3-problem-report, apport-core-dump-handler, apport-gtk. The uploader daemon **whoopsie is C** (separate source).
- **Installed/active**: installed; `apport.service` enabled+active (a oneshot **latch** — it installs the core_pattern hook and stays "active (exited)"); whoopsie.path enabled (inotify on /var/crash); autoreport off; /var/crash empty
- **Category**: crash reporting
- **Implementation**: Python 3 throughout (only `apport-bug` and `is-enabled` are shell); the ~44 KB handler plus python3-apport pulling python3-apt, launchpadlib, requests, yaml
- **Daemon vs command**: kernel-invoked one-shot — the kernel forks a fresh Python interpreter per crash; frontends are interactive commands; whoopsie (C) is the only long-running piece
- **Python dependencies (direct)**: stdlib-heavy in the handler (fcntl, grp, pwd, socket, struct) + `apport.report`, `problem_report`; the report/crashdb layer adds apt/launchpadlib/requests/yaml
- **Native APIs underneath**: **`core_pattern` pipe — verified live**: `|/usr/share/apport/apport -p%p -s%s ... %E`, with `suid_dumpable=2` and `core_pipe_limit=10` set by `start_apport()`; direct pipe, **not** via systemd-coredump (that alternate route exists as `apport-coredump-hook@.service`, dormant here). Reads `/proc/meminfo`, `/proc/<pid>/{stat,exe,cwd,environ}`.
- **IPC/API used**: kernel pipe on stdin (the core itself); AF_UNIX `/run/apport.socket` with `SO_PASSCRED`/`SCM_CREDENTIALS` + fd passing for container crash forwarding; filesystem queue in /var/crash (`.crash`/`.upload`/`.uploaded` markers, whoopsie path-activated); HTTPS to daisy.ubuntu.com (whoopsie/libcurl) and Launchpad (launchpadlib)
- **Privilege model**: **root via core_pattern, unconfined on the active path** — no AppArmor profile for apport itself, no seccomp; explicit `setresuid/setresgid` drops to the crashing user's ids at three sites; handles setuid targets deliberately; /var/crash is `drwxrwsrwt root:whoopsie`. The sandboxed systemd-coredump variant unit (NoNewPrivileges, ProtectSystem=strict, PrivateNetwork, MemoryDenyWriteExecute, SystemCallFilter) exists but does not apply to the direct-pipe route in use here.
- **Boot-critical?**: no — masking it costs only crash reports
- **Performance-sensitive?**: **yes, at crash time under memory pressure** — full CPython start + heavy imports exactly when the system is least healthy. The code is built around this: `core_size_limit = usable_ram() * 3/4` abort, zstd streaming, core_pipe_limit=10 anti-fork-bomb, Nice=9/OOMScoreAdjust=500 on the sandboxed variant.
- **Cross-distro** *(knowledge-based)*: **systemd-coredump (C)** is the mainstream answer (journal storage, coredumpctl, no upload layer); Fedora's ABRT (C daemon + Python plugins) is the closest structural analogue, itself being displaced by systemd-coredump
- **KDE prior art** *(knowledge-based)*: **DrKonqi (C++/Qt)** — migrated to consuming systemd-coredump (drkonqi-coredump-processor units), drives gdb, files to bugs.kde.org. apport's cron cleanup even special-cases `.drkonqi` markers; the two coexist on Kubuntu.
- **Candidate Runix APIs**: core_pattern/core_pipe_limit/suid_dumpable sysctl management; bounded streaming pipe reads; /proc introspection; credential-passing AF_UNIX sockets; setresuid privilege drop; spool-directory management; package attribution of a binary (dpkg lookup)
- **Replacement difficulty**: high — setuid handling, container forwarding, credential verification, privilege-drop ordering, and crash-storm limiting are each subtle and each a security boundary; plus hundreds of package hooks and a report format whoopsie/Error Tracker consume
- **Replacement value**: low-to-moderate — the honest fix is **adopting systemd-coredump for capture** (where the ecosystem already went), not rewriting apport
- **Technically bounded?**: no — crashdb/Launchpad integration, the hook ecosystem, and the upload protocol are open-ended. The narrow slice (accept core, bound size, spool) is cleanly scoped.
- **Phase 4 fit**: **excluded** — root pipeline parsing untrusted crash data is an explicit PLAN.md security-boundary exclusion, and apport's CVE history (privilege escalation via core handling, /var/crash races, container forwarding) is exactly in that area
- **Evidence**: live `cat /proc/sys/kernel/core_pattern` and `core_pipe_limit`; `dpkg -s` across the suite; shebangs + imports; `systemctl cat` on all 5 units + socket; `find -perm /6000` (none); `ls -ld /var/crash`; AppArmor absence checked in /etc/apparmor.d and loaded profiles; handler internals — `drop_privileges()` L209, setresuid L451/480, `start_apport()` L693-709, `usable_ram()` L357, size limit L1049, SCM_CREDENTIALS note L651; `fileutils.py` L34/59/202; `/etc/default/apport`; `/etc/cron.daily/apport` (2026-08-07)

### Cloud provisioning

#### cloud-init

- **Program**: `cloud-init` — first-boot instance provisioning (datasource discovery, network render, users/SSH keys, `#cloud-config` modules)
- **Ubuntu package**: cloud-init 26.1-0ubuntu1~24.04.1 (noble-updates/main, source cloud-init)
- **Installed/active**: installed; all four boot units enabled but the tool is **disabled on this box** — `/etc/cloud/cloud-init.disabled` ("Disabled by Ubuntu live installer after first boot"), instance dir symlinks to `iid-datasource-none` (bare metal, no datasource ever matched)
- **Category**: cloud provisioning
- **Implementation**: Python 3 (~30 datasource modules, ~15 network renderers, `cc_*` config modules). Notable non-Python piece: `ds-identify` is **POSIX shell** — the fast datasource-detection pass avoids starting Python at all when no datasource exists.
- **Daemon vs command**: four boot-stage oneshots (`cloud-init-local` → `cloud-init` → `cloud-config` → `cloud-final`), ordered Before sysinit/sshd/network-online targets
- **Python dependencies (direct)**: yaml, jinja2, requests, jsonschema, jsonpatch, configobj, oauthlib (MAAS), serial (SmartOS), debconf; Recommends python3-apt, software-properties-common
- **Native APIs underneath**: netplan rendering then `netplan generate/apply`; systemd unit ordering as the execution engine; IMDS HTTP to 169.254.169.254 across ~10 providers; growpart/gdisk; dhcpcd; udev; SSH host-key generation
- **IPC/API used**: subprocess shell-out dominant (`systemctl`, `hostnamectl`, `udevadm`, `netplan`, `apt`); HTTP to metadata endpoints; on-disk state under /var/lib/cloud as cross-stage IPC
- **Privilege model**: root at boot, unconfined, executing user-supplied `runcmd`/`bootcmd` from the datasource — **a root-level remote-code-execution path by design; a major security boundary**
- **Boot-critical?**: **YES** — two stages block sysinit.target; on a cloud instance failure means no network, no SSH keys, no recovery
- **Performance-sensitive?**: yes — directly on boot latency; upstream mitigates with the shell ds-identify fast path
- **Cross-distro** *(knowledge-based)*: cloud-init is itself the cross-distro standard (BSD renderers in this very tree). The non-Python alternatives already exist: **Ignition (Go)** and **Afterburn (Rust)** on Fedora CoreOS.
- **KDE prior art** *(knowledge-based)*: n/a
- **Candidate Runix APIs**: none directly — **PLAN.md explicitly excludes cloud-init from Phase 4** (fails not-boot-critical, bounded, and Runix-API-backed criteria). Its constituent surfaces (network config, unit control, user/key management) are worth exposing as Runix building blocks for other tools.
- **Replacement difficulty**: very high — ~30 provider protocols, ~15 renderers across 5 OS families, a de facto public config format where **bug-compatibility is the bar**
- **Replacement value**: low relative to cost — boot-latency win already captured by ds-identify; on this machine the local benefit is zero
- **Technically bounded?**: no — scope defined by an open-ended set of third-party providers
- **Evidence**: entry-point shebang (setuptools shim, cloud-init==26.1); `dpkg -s`; `systemctl cat` on all four units (Before/After chains); `file ds-identify` (POSIX shell); `/var/lib/cloud/instance` symlink; `cloud-init status` → disabled; `/etc/cloud/cloud-init.disabled`; datasource_list in `90_dpkg.cfg`; IMDS grep across sources/ (2026-08-07)

### Desktop administration

#### language-selector

- **Program**: `check-language-support` (CLI) + `ls-dbus-backend` (root D-Bus backend); GTK frontend in language-selector-gnome
- **Ubuntu package**: language-selector-common 0.225 (noble/main, section admin, source language-selector)
- **Installed/active**: installed; backend not resident — D-Bus-activated on demand (`User=root`)
- **Category**: desktop administration
- **Implementation**: Python 3 throughout; library `language_support_pkgs.py` + `LanguageSelector/` package
- **Daemon vs command**: both — one-shot CLI + short-lived root D-Bus-activated service on a GLib loop
- **Python dependencies (direct)**: `dbus` + mainloop + service, `gi.repository.GObject`, `apt` (`apt.Cache()`). Depends: python3-apt, python3-dbus, iso-codes, accountsservice.
- **Native APIs underneath**: libapt (language-pack resolution), GLib loop, iso-codes data, accountsservice for per-user language
- **IPC/API used**: system bus `com.ubuntu.LanguageSelector`, methods incl. `SetSystemDefaultLanguageEnv` (writes `/etc/default/locale`); polkit action `com.ubuntu.languageselector.setsystemdefaultlanguage` (`auth_admin` / `auth_admin_keep`)
- **Privilege model**: root backend; each privileged method calls `_authWithPolicyKit()` → `CheckAuthorization` (system-bus-name subject, AllowUserInteraction) before touching /etc. CLI is unprivileged read-only.
- **Boot-critical?**: no (the `/etc/default/locale` it writes is boot-read; the tool never runs at boot)
- **Performance-sensitive?**: no — dominated by one-off `apt.Cache()` construction
- **Cross-distro** *(knowledge-based)*: Ubuntu-specific language-pack model; Fedora langpacks dnf plugin; openSUSE YaST; Arch none
- **KDE prior art** *(knowledge-based)*: Plasma's Region & Language KCM (C++/Qt/KConfig) covers the locale-write half; on Kubuntu it shells to this same language-pack machinery for the apt half
- **Candidate Runix APIs**: locale get/set with atomic `/etc/default/locale` write + validation; language-support completeness query over libapt; polkit check helper; D-Bus service host with sender authorization
- **Replacement difficulty**: low-to-moderate — the backend is ~100 lines of D-Bus + polkit + config write; the moderate part is the apt dependency-traversal parity in `language_support_pkgs.py`
- **Replacement value**: moderate — removes a root Python D-Bus service; apt-cache load is the visible slowness in the language UI; Ubuntu-only and rarely invoked
- **Technically bounded?**: yes — two D-Bus methods, one polkit action, one config file, one well-defined query
- **Evidence**: shebangs + import greps on both entry points; `language_support_pkgs.py` (`apt.Cache()`); `dpkg -s`; D-Bus activation + policy files; polkit policy; `_authWithPolicyKit` at ls-dbus-backend:27-55 (2026-08-07)

#### usb-creator

- **Program**: `usb-creator-helper` (root D-Bus backend) + `usb-creator-gtk` ("Startup Disk Creator")
- **Ubuntu package**: usb-creator-common 0.3.17 (noble/main, section admin, source usb-creator); -gtk also installed
- **Installed/active**: installed; helper D-Bus-activated on demand (`User=root`), exits via its own `Shutdown` method
- **Category**: desktop administration, hardware (block devices)
- **Implementation**: Python 3; `usbcreator/` support package
- **Daemon vs command**: D-Bus-activated root service on a GLib loop, started per operation
- **Python dependencies (direct)**: `dbus`, `gi.repository.{GObject,GLib,UDisks}`. Depends: python3-dbus, **gir1.2-udisks-2.0, udisks2**, xorriso, python3-debian.
- **Native APIs underneath**: **UDisks2 — confirmed and load-bearing**: `UDisks.Client.new_sync()`, object-manager enumeration of `/org/freedesktop/UDisks2/block_devices/`, `MountPoints` cached properties, `call_unmount_sync()` before writing, `check_system_internal()` refusing internal disks. The actual bytes go through an in-process Python `_builtin_dd` — UDisks2 owns discovery/safety/unmount, not the copy.
- **IPC/API used**: system bus `com.ubuntu.USBCreator` — methods `Image(source, target, allow_system_internal)`, `KVMTest`, `Shutdown`; signal `Progress(u)`. Outbound to UDisks2 and PolicyKit1. Polkit actions `com.ubuntu.usbcreator.image` and `.kvm` — both `allow_any=no`, `allow_active=auth_admin_keep` (stricter than language-selector).
- **Privilege model**: root via D-Bus activation; every method starts with `check_polkit(sender, conn, action)` resolving the caller and calling `CheckAuthorization` (code annotated "Taken from Jockey 0.5.3"). Safety layered on top: internal-disk refusal + unmount-all before write.
- **Boot-critical?**: no
- **Performance-sensitive?**: yes, moderately — streams a 1-6 GB ISO through a Python copy loop while emitting Progress on the same main loop; USB is usually the bottleneck but the loop is Python
- **Cross-distro** *(knowledge-based)*: problem is universal, tools are per-distro — Fedora Media Writer (C++/Qt), GNOME Disks restore (C, UDisks2), balenaEtcher (Electron). The UDisks2 dependency is fully cross-distro; only the D-Bus/polkit surface is Ubuntu's.
- **KDE prior art** *(knowledge-based)*: strong — **KDE ISO Image Writer** (C++/KAuth helper) is the direct analogue, and **Solid** wraps the same UDisks2 interfaces for removable-device discovery. A proven design to copy: Solid/UDisks2 discovery + polkit authorization + native write loop.
- **Candidate Runix APIs**: UDisks2-backed block enumeration + removable-vs-internal classification + unmount-all + safe write handle; ISO inspection; streaming progress events; polkit action check
- **Replacement difficulty**: moderate — the pieces are well-trodden; the cost is correctness under adversarial conditions (enumeration races, the internal-disk check whose failure destroys a system disk, sync/flush before reporting done)
- **Replacement value**: **high** — removes a root Python service writing raw bytes to block devices, replaces a Python copy loop on a multi-GB path with native I/O, and lands on the UDisks2 abstraction Runix needs anyway for storage features
- **Technically bounded?**: yes — three methods, two polkit actions, one native dependency, one data flow
- **Evidence**: shebang; import grep (line 18 `UDisks`); UDisks call sites at 38-84 and 155/174-180; `Image()` body 168-183 (check_polkit → check_system_internal → unmount_all → _builtin_dd); `check_polkit` at 196-228; `dpkg -s usb-creator-common`; D-Bus service (`User=root`) + polkit policy files; UDisks-2.0.typelib present (2026-08-07)

### Categories with no first-party Python presence

Verified on this machine (2026-08-07):

- **Service management**: `systemctl` is a C ELF binary; systemd's entire toolchain is C.
  No Python anywhere in the service-management path.
- **Users/groups**: `adduser` is **Perl** (`#!/usr/bin/perl`); `accounts-daemon` is a C ELF.
  useradd/usermod are C (shadow-utils).
- **Hardware core**: udev/udevadm are C; the Python presence in hardware is limited to
  client CLIs for C daemons (switcherooctl, powerprofilesctl — table-only rows).
- **Installer**: not installed on this machine (no subiquity/ubiquity), out of scope per
  the installed-only rubric. Known from general knowledge (labeled as such): subiquity,
  the Ubuntu server installer, is Python — and an explicit PLAN.md Phase 4 exclusion anyway.
- **Diagnostics**: the 105 bpfcc-tools scripts are Python-over-BCC; native successors
  (bpftrace, libbpf-tools) already exist upstream — replacement is an upstream adoption
  question, not a Runix rewrite target.

## Cross-distro equivalents

Knowledge-based (no network access during survey); Ubuntu column verified locally.

| Capability | Ubuntu (Python) | Debian | Fedora/RHEL | NixOS | Arch | Native impl exists? |
|---|---|---|---|---|---|---|
| Repo administration | add-apt-repository | same package | dnf5 config-manager (**C++**) | declarative config | manual pacman.conf | yes (dnf5) |
| Privileged package D-Bus service | aptdaemon (vestigial) | same / PackageKit | PackageKit (**C**) | n/a | PackageKit (rare) | yes (PackageKit) |
| command-not-found | command-not-found | same | PackageKit-cnf (**C**) | programs.sqlite hook | pkgfile (**C**) | yes |
| Security/update status | ubuntu-security-status | debsecan (Py) | dnf updateinfo | vulnix | arch-audit (**Rust**) | partial |
| Automatic updates | unattended-upgrades | same | dnf-automatic (Py) | system.autoUpgrade | none standard | no |
| GUI updates | update-manager | GNOME Software | GNOME Software (**C**) via PackageKit | n/a | Discover (**C++**) | yes |
| Release upgrade | do-release-upgrade | manual apt | dnf system-upgrade (Py) | nixos-rebuild | rolling | partial (zypper dup C++) |
| Crash handling | apport | same available | systemd-coredump (**C**) / ABRT | systemd-coredump | systemd-coredump | yes |
| Driver management | ubuntu-drivers | isenkram | none (third-party repos) | declarative | none | no |
| Entitlement client | pro | n/a | subscription-manager (Py) | n/a | n/a | no |
| Instance provisioning | cloud-init | same | cloud-init / Ignition (**Go**) | declarative | cloud-init | yes (Ignition/Afterburn) |
| Network config layer | netplan CLI | available, non-default | networkd/NM direct | declarative | networkd/NM direct | **the C core ships in Ubuntu's own archive** |
| Firewall frontend | ufw | same | firewalld (Py) | declarative nft | raw nft (**C**) | partial (nft) |
| networkd dispatcher | networkd-dispatcher | same | same (Py); NM-dispatcher (**C**) | same | same | yes, for NM only |
| USB image writer | usb-creator | n/a | Fedora Media Writer (**C++**) | n/a | n/a | yes |
| Language packs | language-selector | n/a | dnf langpacks (Py) | declarative | n/a | no |

## Phase 4 first-replacement shortlist

**Explicitly provisional.** This scores today's evidence; the actual pick happens at the
Phase 4 gate, after Phase 1-3 APIs exist. Scoring: PLAN.md's five criteria, 0-2 each.

| Candidate | Clearly admin | Mostly Python | Not boot-critical | Bounded | Meaningful | Total |
|---|---|---|---|---|---|---|
| **netplan CLI** | 2 | 2 | 2 (Python never on boot path) | 2 | 2 | **10** |
| ubuntu-security-status | 2 | 2 | 2 | 2 | 1 | 9 |
| add-apt-repository | 2 | 2 | 2 | 1 (PPA/key fetch edge) | 2 | 9 |
| networkd-dispatcher | 2 | 2 | 2 | 2 | 1 (inert on NM boxes) | 9 |
| command-not-found | 1 | 2 | 2 | 2 | 1 | 8 |
| usb-creator | 1 | 2 | 2 | 2 | 1 | 8 |
| ubuntu-drivers (query layer) | 2 | 2 | 2 | 1 | 1 | 8 |

Excluded classes (fail PLAN.md's "do not begin with" list regardless of score):
unattended-upgrades (unattended security mutation + shutdown-inhibitor hazard), apport
(root parsing of untrusted crash data; CVE history), cloud-init (boot-critical, explicit
exclusion), do-release-upgrade (bricks machines; runtime-downloaded code), ubuntu-pro-client
(proprietary contract protocol — wrap `pro api`, don't replace), update-manager (GUI over
a vestigial backend), aptdaemon (vestigial; let it die).

**Recommendation (provisional, two-track):**

1. **Introspection track — ubuntu-security-status.** Read-only over libapt origins, fully
   unprivileged, output admins actually read, and it doubles as the Phase 1 forcing
   function for the apt query API. Lowest risk, immediate value.
2. **Substitution track — netplan CLI.** The strongest architectural fit found in this
   survey: Canonical already split the C core (libnetplan1 + boot generator) from the
   Python CLI as separate packages, so Runix replaces exactly one package and inherits
   the parser, semantics, and boot safety untouched. An R binding to libnetplan1's 97-symbol
   C ABI is native-first Runix by construction. Caveat to resolve at the gate: `rctl`-side
   packaging must not drag r-base-core into `priority: important` territory uninvited —
   ship as a coexisting alternative binary, as PLAN.md's Phase 4 already requires.

Codex-review caveats, confirmed by the records: software-properties is broader than it
looks (PackageKit dependency, GTK frontend, D-Bus backend — scope any replacement to the
CLI + deb822 path first), and command-not-found, while the most bounded target, exercises
almost none of the privileged-administration architecture, so it proves little.
networkd-dispatcher scores well but, per its record, is a native-daemon shape: it would
prove the native-helper half of Runix with R as client only, not an R showcase.

## Appendix A: Excluded hits and why

Every sweep-A/B package not covered above, with exclusion class (full sweep output
preserved in the survey scratchpad; counts in Appendix B):

- **Python-library CLI stubs** (the executable exists because a library ships a
  console script, not because Ubuntu administers anything with it): python3-serial,
  python3-numpy, python3-jsonpatch, python3-websocket, python3-unidiff, python3-speechd,
  python3-pystache, python3-pysmi, python3-pygments, python3-netaddr, python3-markdown-it,
  python3-mako, python3-keyring, python3-jsonschema, python3-json-pointer, python3-chardet,
  python3-babel, isympy-common
- **Interpreter infrastructure**: python3.12, python3-minimal (py3compile, pydoc stubs)
- **Dev tooling**: devscripts (8 scripts), gyp, patchutils, clang-18
- **Third-party applications** (not first-party administration): glances (universe;
  its `/etc/systemd/system/glances.service` is a local admin addition), duplicity,
  proton-vpn-gtk-app, piper/ratbagd (gaming-mouse config)
- **Desktop end-user applications**: gnome-shell (2 hits), gnome-browser-connector,
  gnome-tweaks, gnome-terminal, gnome-menus, orca (screen reader), mesa-vulkan-drivers
  (shader tool script)
- **Miscellaneous support scripts**: rsync (rrsync restricted-shell helper), iproute2
  (one Python script — `routel`; trivia: even iproute2 ships a Python rewrite of one tool)

Borderline calls, documented: hplip kept as table-only (main component, root D-Bus
service `com.hp.hplip`, but HP-upstream printing rather than Ubuntu first-party admin);
ssh-import-id and ec2metadata table-only (bounded single-purpose provisioning helpers);
gnome-browser-connector excluded (browser integration, not administration).

## Appendix B: Raw enumeration counts

- Sweep A: 190 Python-shebang executables in `/usr/bin` + `/usr/sbin` (0 at
  `/usr/libexec` depth ≤ 2)
- Sweep B: those 190 map to 62 packages; 105/190 belong to `bpfcc-tools` alone
- Sweep C: 18 installed packages depend on `python3-apt`, nearly all first-party admin
- Sweep D: 19 systemd service files resolve to Python `ExecStart` (incl. apport, cloud-init,
  unattended-upgrades, networkd-dispatcher, ubuntu-pro timers, update-notifier-download);
  5 system D-Bus activation services exec Python (aptd, SoftwareProperties,
  LanguageSelector, USBCreator, hplip) + 1 session (gnome-browser-connector)
- Sweep E: 232 executable Python scripts across the 23 candidate packages (incl.
  out-of-PATH: `/usr/lib/command-not-found`, `/usr/lib/update-notifier/apt-check`,
  `/usr/share/unattended-upgrades/unattended-upgrade-shutdown`)
- Unit/timer state at survey time: unattended-upgrades.service enabled+active,
  apt-daily{,-upgrade}.timer enabled+active, update-notifier-download.timer
  enabled+active, motd-news.timer enabled+active, apport.service enabled+active,
  ua-timer.timer enabled (inactive), networkd-dispatcher.service enabled (inactive),
  cloud-init.service enabled (inactive post-boot)
