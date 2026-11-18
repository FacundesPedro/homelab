#!/usr/bin/env bash
# 10-create-vm.sh - create VM 200 ("strata") on prox-2. Ubuntu install only.
#
#   bash 10-create-vm.sh
#   VMID=201 DISK_GB=400 bash 10-create-vm.sh
#
# The GPU is NOT attached here. Finish the Ubuntu install and shut the VM down,
# then run 20-attach-gpu.sh.
#
# Topology note: Proxmox has no `threads=` knob, so `-smp` is sockets x cores
# with one thread each. 24 cores makes the guest look like 24 physical cores;
# Strata would then default to 23 workers and lose ~37% (its issue #3417).
# 30-guest-setup.sh pins `--pool-workers 13` explicitly instead.

set -euo pipefail

VMID="${VMID:-200}"
VMNAME="${VMNAME:-strata}"
STORAGE="${STORAGE:-nvme}"
ISO_STORAGE="${ISO_STORAGE:-local}"
ISO_NAME="${ISO_NAME:-ubuntu-26.04.1-live-server-amd64.iso}"
DISK_GB="${DISK_GB:-380}"
MEMORY_MB="${MEMORY_MB:-53248}"     # 52 GiB: VFIO pins the whole guest RAM, so this
                                    # leaves ~8 GiB for the host. 58 GiB caused real
                                    # memory pressure; 56 GiB is a GPU-reset risk, not RAM
CORES="${CORES:-24}"                # 1 socket, 24 cores, no SMT (PVE limitation)
MACADDR="${MACADDR:-BC:24:11:53:54:52}"  # reserve this on the router
BRIDGE="${BRIDGE:-vmbr0}"
START="${START:-0}"

[ "$(id -u)" -eq 0 ] || { echo "run as root on the Proxmox host"; exit 1; }
command -v qm >/dev/null || { echo "qm not found - is this the Proxmox host?"; exit 1; }

say() { printf '\n== %s ==\n' "$*"; }

say "Pre-flight"
if qm status "$VMID" >/dev/null 2>&1; then
    echo "VM $VMID already exists:"; qm config "$VMID" | sed 's/^/  /'
    echo "Refusing to touch it. Use a different VMID=."
    exit 1
fi
ISO_PATH="/var/lib/vz/template/iso/$ISO_NAME"
if [ -f "$ISO_PATH" ]; then
    echo "  iso: $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
else
    echo "  ISO not in $ISO_STORAGE: $ISO_PATH"
    echo "  available:"
    ls -1 /var/lib/vz/template/iso/*.iso 2>/dev/null | sed 's/^/    /' || true
    echo "  set ISO_NAME= or put the ISO in ${ISO_STORAGE} first."
    exit 1
fi
AVAIL_KB=$(df -Pk /mnt/nvme | awk 'NR==2{print $4}')
NEED_KB=$((DISK_GB * 1024 * 1024 + 20 * 1024 * 1024))
echo "  nvme free: $((AVAIL_KB / 1024 / 1024)) GiB, want $((NEED_KB / 1024 / 1024)) GiB (disk + 20 GiB headroom)"
[ "$AVAIL_KB" -ge "$NEED_KB" ] || { echo "not enough free space on /mnt/nvme"; exit 1; }

say "Create VM $VMID ($VMNAME)"
qm create "$VMID" \
    --name "$VMNAME" \
    --ostype l26 \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=0" \
    --cpu host \
    --sockets 1 --cores "$CORES" --vcpus "$CORES" \
    --memory "$MEMORY_MB" --balloon 0 \
    --scsihw virtio-scsi-single \
    --scsi0 "${STORAGE}:${DISK_GB},format=qcow2,ssd=1,discard=on,iothread=1,cache=none" \
    --ide2 "${ISO_STORAGE}:iso/${ISO_NAME},media=cdrom" \
    --boot order=ide2 \
    --net0 "virtio,bridge=${BRIDGE},macaddr=${MACADDR}" \
    --serial0 socket \
    --vga std \
    --agent enabled=1 \
    --onboot 0 \
    --description "Strata HIP engine (gfx1100). Ubuntu 26.04 + RX 7900 XT passthrough via hookscript. GPU attached after install."

qm config "$VMID" | sed 's/^/  /'

cat <<EOF

== Next: install Ubuntu 26.04 Server ==

  qm start $VMID
  # then open the VM console in the Proxmox UI (noVNC)

Installer answers that matter:
  - Ubuntu Server (not minimized)
  - network: DHCP  (reserve MAC $MACADDR on the router)
  - storage: entire disk, do NOT use LVM, ext4
  - server name: $VMNAME
  - install OpenSSH server: yes, import/paste your public key
  - Ubuntu Pro: skip, featured snaps: none

After the install finishes, shut the VM down cleanly, then:
  bash 20-attach-gpu.sh
EOF

[ "$START" = "1" ] && qm start "$VMID" || true
