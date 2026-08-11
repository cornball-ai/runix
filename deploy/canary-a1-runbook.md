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

- **Host:** any Linux host with KVM (the fleet's designated canary host — see
  `roadmap.md`). A1 uses only a disposable **guest**; the host's
  NVIDIA/kernel/boot/networking/SSH/container-runtime are never touched. The
  one-time host setup is an apt install of the hypervisor stack
  (`qemu-system-x86 libvirt-daemon-system virtinst cloud-image-utils`) plus
  adding the invoking user to the `libvirt`/`kvm` groups.
- **Hypervisor:** libvirt `qemu:///system`, driven by the invoking user via
  libvirt-group membership (no root). Disks are streamed into the default pool
  with `vol-upload` (no direct write to `/var/lib/libvirt`).
- **Base image:** Ubuntu 24.04 Noble cloud image,
  `sha256 0533b0655c32e68b31d792ecd6ccfca95abdbc536c4446874fe0513bd4140ffe`
  (verified against the published `SHA256SUMS`).
- **Guest:** `runix-canary-a1`, 4 GiB / 2 vCPU / 20 GiB, NAT networking,
  cloud-init seeds a dedicated `id_canary` ssh key. Reached at its DHCP-leased
  address on the libvirt NAT network (ephemeral; recorded in
  `$HOME/canary/guest.ip`).

## Cleanup boundary

The guest is disposable. Teardown removes only the **owned** domain and its
storage and leaves nothing on the host but the `$HOME/canary` working dir (base
image, keypair, scripts). It is deliberately narrow: the domain carries an
ownership marker in its description (stamped at create), and `destroy` refuses
an empty/ambiguous name, refuses a same-named domain that lacks the marker,
never removes the shared NAT network or any other domain, and asserts the domain
and its volumes are actually gone afterward:

    deploy/canary/provision.sh destroy   # owned domain + its storage only

Re-running `provision.sh` (no arg) tears down and rebuilds from the verified
base — cheaper and more honest than keeping a mutated guest around as a snapshot
to trust. The guest is cattle: after a run, preserve the manifest and evidence
(below), then `provision.sh destroy`.

## Pinned stack (installation manifest)

Installed from pinned sources (A1 installs the R packages from source; janssonr
from the cornball apt binary; the broker built from its pinned source and
socket-activated — mirrors runix CI).

The stack the 7 gates passed on (post the actor-ownership fix — runix #45,
rsystemd #12):

| component | version | commit / tag | source |
|---|---|---|---|
| runix | 0.0.1.8 | `3ef158a` | source archive |
| pkgstate | 0.0.1.8 | `a351b15` | source archive |
| rsystemd | 0.0.1.12 | `cb1901a` | source archive |
| rctl | 0.0.1.6 | `6058aba` | source archive |
| janssonr | 0.0.1.3 | `11a989a` | `r-cornball-janssonr` (cornball apt repo) |
| runix-audit-broker | — | `4a5a8f7` (`v0.0.1`) | source archive, built in-guest |

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

## Results (2026-08-11, guest runix-canary-a1)

**All 7 gates pass** on a real Noble guest with host systemd/polkit and the
socket-activated broker, driven by the unprivileged `canary` (uid 1001):

| gate | result | evidence |
|---|---|---|
| 1 broker-backed system durability | PASS | `system_durable_audit=true`, `audit_scope=system` for uid 1001 |
| 2 preview no-effect | PASS | InvocationID unchanged across `--preview` |
| 3 restart + InvocationID | PASS | `method=invocation_id`, id advances, `actor=uid:1001` |
| 4 durable intent+outcome | PASS | one `correlation_id`, `actor=uid:1001`, `broker.peer.uid=1001` |
| 5 timeout audited | PASS | `runix_timeout`, `observed.active_state=activating`, timeout outcome recorded |
| 6 hard death | PASS | SIGKILL mid-op; open intent still present after a broker restart (detectability, not recovery) |
| 7 unrelated unit denied | PASS | `runix_unauthorized`, exit 1 |

### Findings the canary surfaced

1. **R version floor (deployment).** The `r-cornball-janssonr` apt binary needs
   `r-base-core >= 4.6.0`; stock Ubuntu Noble ships 4.3.3. The fleet must get R
   from the CRAN/r2u apt repo, not the distro. A0 packaging must encode this.
2. **`actor` ownership bug (fixed).** rsystemd put `actor` in the audit record;
   the broker owns `actor` (`SO_PEERCRED`) and rejected it `schema_invalid`, so
   every unprivileged system-scope mutation fail-closed refused. Fixed: runix
   #45 (`actor` is sink-derived framing; broker adapter rejects reserved keys)
   and rsystemd #12 (builders omit `actor`; use `runix::audit_actor()`). The
   rsystemd→broker path had no end-to-end test — CI only exercised the direct
   client.
3. **rsystemd has no CI workflow.** Part of why (2) slipped through. A
   production-path integration test (unprivileged mutation → real broker →
   durable records) belongs in CI; this runbook's gate suite is its manual form.

### Reproduce / teardown

`gates.sh` re-runs all seven as `canary`. The guest is disposable:
`provision.sh destroy` removes the domain and all storage; nothing remains on
the host but `~/canary`.
