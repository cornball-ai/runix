#!/bin/bash
# Provision the disposable A1 canary guest on troy-g5. Run ON g5 as troy.
#
# Rootless: qemu:///system via troy's libvirt-group membership, disks streamed
# into the default pool with vol-upload (no direct write to /var/lib/libvirt),
# NAT networking, cloud-init seeds the canary ssh key. The host is untouched
# beyond the pool volumes and ~/canary; teardown removes both.
#
#   deploy/canary/provision.sh          # provision (idempotent: recreates)
#   deploy/canary/provision.sh destroy  # tear the guest down, remove storage
set -euo pipefail

NAME=runix-canary-a1
POOL=default
DIR="$HOME/canary"
BASE="$DIR/noble-server-cloudimg-amd64.img"
DISK_GB=20
RAM_MB=4096
VCPUS=2
C="virsh -c qemu:///system"

teardown() {
    echo "== teardown =="
    $C destroy "$NAME" 2>/dev/null || true
    $C undefine "$NAME" --remove-all-storage 2>/dev/null || true
    $C vol-delete --pool "$POOL" "${NAME}.qcow2" 2>/dev/null || true
    $C vol-delete --pool "$POOL" "${NAME}-seed.iso" 2>/dev/null || true
    echo "torn down."
}

if [ "${1:-}" = "destroy" ]; then
    teardown
    exit 0
fi

[ -f "$BASE" ] || { echo "base image missing: $BASE" >&2; exit 1; }
[ -f "$DIR/id_canary.pub" ] || { echo "canary pubkey missing" >&2; exit 1; }

cd "$DIR"
teardown

echo "== build guest disk (resized copy of the verified base) =="
rm -f guest.qcow2 seed.iso
cp -f "$BASE" guest.qcow2
qemu-img resize guest.qcow2 "${DISK_GB}G"

echo "== cloud-init seed (ssh key only; no package pulls at boot) =="
PUB=$(cat id_canary.pub)
cat > user-data <<EOF
#cloud-config
hostname: $NAME
ssh_pwauth: false
package_update: false
users:
  - name: ubuntu
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    shell: /bin/bash
    ssh_authorized_keys:
      - $PUB
EOF
cat > meta-data <<EOF
instance-id: $NAME
local-hostname: $NAME
EOF
cloud-localds seed.iso user-data meta-data

echo "== ensure storage pool '$POOL' =="
if ! $C pool-info "$POOL" >/dev/null 2>&1; then
    $C pool-define-as "$POOL" dir --target /var/lib/libvirt/images
    $C pool-build "$POOL" 2>/dev/null || true
    $C pool-start "$POOL"
    $C pool-autostart "$POOL"
fi

echo "== stream disk + seed into pool '$POOL' =="
$C vol-create-as "$POOL" "${NAME}.qcow2" "${DISK_GB}G" --format qcow2
$C vol-upload --pool "$POOL" "${NAME}.qcow2" guest.qcow2
SEED_BYTES=$(stat -c%s seed.iso)
$C vol-create-as "$POOL" "${NAME}-seed.iso" "$SEED_BYTES" --format raw
$C vol-upload --pool "$POOL" "${NAME}-seed.iso" seed.iso
DISK_PATH=$($C vol-path --pool "$POOL" "${NAME}.qcow2")
SEED_PATH=$($C vol-path --pool "$POOL" "${NAME}-seed.iso")

echo "== virt-install (import) =="
virt-install --connect qemu:///system \
    --name "$NAME" \
    --memory "$RAM_MB" --vcpus "$VCPUS" \
    --disk "path=$DISK_PATH,format=qcow2,bus=virtio" \
    --disk "path=$SEED_PATH,device=cdrom" \
    --os-variant ubuntu24.04 \
    --network network=default,model=virtio \
    --graphics none --noautoconsole --import

echo "== wait for DHCP lease =="
IP=""
for _ in $(seq 1 60); do
    IP=$($C net-dhcp-leases default 2>/dev/null \
        | awk '/ipv4/{print $5}' | head -1 | cut -d/ -f1)
    [ -n "$IP" ] && break
    sleep 3
done
$C net-dhcp-leases default || true
if [ -z "$IP" ]; then
    echo "NO LEASE YET; check 'virsh -c qemu:///system console $NAME'" >&2
    exit 1
fi
echo "$IP" > "$DIR/guest.ip"
echo "DONE name=$NAME ip=$IP"
