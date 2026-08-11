# Canary A1 — Runix runtime stack on a real systemd host

Status: runbook (executable). A1 is the **Runix-only** canary slice: prove the
whole mutation boundary on a real systemd/polkit host, with no Viento in the
loop. Viento → rctl (transport, principal, remote policy) is a later slice (B).
A0 — reproducible apt-installed `.deb` stack — is the deployment arc that
follows A1 (see `build-debs.sh`, currently historical/broken).

## Why a real VM, not a container

The gates exercise host systemd (job management, `InvocationID`), polkit
authorization, and `SO_PEERCRED` peer identity at the broker socket. Containers
do not faithfully reproduce any of those, so A1 runs in a disposable KVM guest.

## VM mechanism

- **Host:** troy-g5 (the designated canary). A1 uses only a disposable **guest**;
  the host's NVIDIA/kernel/boot/networking/SSH/container-runtime are never
  touched. The one-time host setup was an apt install of the hypervisor stack
  (`qemu-system-x86 libvirt-daemon-system virtinst cloud-image-utils`) plus
  adding `troy` to the `libvirt`/`kvm` groups.
- **Hypervisor:** libvirt `qemu:///system`, driven by `troy` via libvirt-group
  membership (no root). Disks are streamed into the default pool with
  `vol-upload` (no direct write to `/var/lib/libvirt`).
- **Base image:** Ubuntu 24.04 Noble cloud image,
  `sha256 0533b0655c32e68b31d792ecd6ccfca95abdbc536c4446874fe0513bd4140ffe`
  (verified against the published `SHA256SUMS`).
- **Guest:** `runix-canary-a1`, 4 GiB / 2 vCPU / 20 GiB, NAT networking,
  cloud-init seeds a dedicated `id_canary` ssh key. Reached from g5 at the
  DHCP-leased 192.168.122.0/24 address (ephemeral; recorded in `~/canary/guest.ip`).

## Cleanup boundary

The guest is disposable. Teardown removes the domain and all its storage and
leaves nothing on the host but the `~/canary` working dir (base image, keypair,
scripts):

    deploy/canary/provision.sh destroy   # virsh destroy + undefine --remove-all-storage

Re-running `provision.sh` (no arg) tears down and rebuilds from the verified
base. Take a `virsh snapshot-create-as runix-canary-a1 clean` after install if a
repeatable pre-gate state is wanted.

## Pinned stack (installation manifest)

Installed from pinned sources (A1 installs the R packages from source; janssonr
from the cornball apt binary; the broker built from its pinned source and
socket-activated — mirrors runix CI).

| component | version | commit / tag | source |
|---|---|---|---|
| runix | 0.0.1.7 | `263de78` | local archive |
| pkgstate | 0.0.1.8 | `a351b15` | local archive |
| rsystemd | 0.0.1.11 | `95e72ce` | local archive |
| rctl | 0.0.1.6 | `6058aba` | local archive |
| janssonr | 0.0.1.3 | `11a989a` | `r-cornball-janssonr` (cornball apt repo) |
| runix-audit-broker | — | `4a5a8f7` (`v0.0.1`) | local archive, built in-guest |

## In-guest fixtures

- **Principal:** `canary` (uid 1001, no sudo) — the unprivileged actor under test.
- **Target unit:** `runix-canary.service` — a harmless `sleep infinity`, never an
  existing service.
- **polkit:** `49-runix-canary.rules` grants `canary` `manage-units` for
  **only** `runix-canary.service`; every other unit falls through to deny.

## Acceptance gates (codex)

1. `rctl capabilities` proves broker-backed **system** durability for the
   unprivileged principal (`system_durable_audit: true`, `audit_scope: "system"`).
2. Preview proves **no effect**.
3. Restart proves **InvocationID advancement** and verified post-state.
4. Matching durable **intent + outcome** records, same `correlation_id`, actor
   `uid:1001`.
5. Graceful **timeout/cancellation** produces an audited error carrying observed
   state.
6. **Hard process death** (SIGKILL mid-op): the open intent remains *detectable*
   across a broker restart. Reported honestly as detectability — nothing
   reconciles or closes it in A1.
7. **Negative authorization:** an unrelated unit is denied for `canary`.

## Reproduce

    # on troy-g5 as troy, with ~/canary/{provision.sh,id_canary*,noble-*.img}
    bash ~/canary/provision.sh                 # provision guest, writes guest.ip
    # stage payload (pinned source tarballs + scripts) into the guest, then:
    bash /tmp/canary/install-stack.sh /tmp/canary
    bash /tmp/canary/setup-canary.sh
    bash /tmp/canary/gates.sh                   # runs the 7 gates as `canary`

## Results

_Filled in after the gate run — see the "A1 results" section appended below._
