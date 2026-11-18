#!/usr/bin/env bash
# 20-attach-gpu.sh - attach the RX 7900 XT + its HDMI audio and the handoff
# hookscript to VM 200.
#
# Run after the Ubuntu install, with the VM shut down:
#   bash 20-attach-gpu.sh
#
# Two hostpci entries, on purpose:
#   hostpci0: 05:00.0  GPU, single function -> QEMU advertises PCIe AtomicOp
#                      completers, which ROCm needs
#   hostpci1: 05:00.1  HDMI audio, its own root port -> the VM owns IOMMU
#                      group 33, so vfio-pci can reset the whole device
#
# Passing `05:00` (both functions on one root port) makes the GPU multifunction
# and strips atomics. NOT passing the audio makes vfio-pci refuse the reset:
#   "Cannot reset device 0000:05:00.0, depends on group 33 which is not owned"

set -euo pipefail

VMID="${VMID:-200}"
GPU="${GPU:-0000:05:00.0}"
AUDIO="${AUDIO:-0000:05:00.1}"
HOOKSCRIPT="${HOOKSCRIPT:-nvme:snippets/strata-gpu-handoff.sh}"
HOOKSCRIPT_LOCAL="${HOOKSCRIPT_LOCAL:-/mnt/nvme/snippets/strata-gpu-handoff.sh}"

pass=0 warn=0 fail=0
ok()   { printf '  [ OK ] %s\n' "$*"; pass=$((pass+1)); }
note() { printf '  [WARN] %s\n' "$*"; warn=$((warn+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
say()  { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root on the Proxmox host"; exit 1; }

responds() {
    local header
    header=$(dd if="/sys/bus/pci/devices/$1/config" bs=1 skip=14 count=1 2>/dev/null |
        od -An -tu1 | tr -d ' ')
    [ -n "$header" ] && [ "$header" != "255" ]
}

say "Pre-flight"
qm status "$VMID" >/dev/null 2>&1 || { echo "VM $VMID does not exist (run 10-create-vm.sh)"; exit 1; }
STATE=$(qm status "$VMID" | awk '{print $2}')
if [ "$STATE" = "stopped" ]; then ok "VM $VMID is stopped"; else bad "VM $VMID is $STATE - shut it down first"; fi

for dev in "$GPU" "$AUDIO"; do
    if [ -e "/sys/bus/pci/devices/$dev" ]; then
        ok "$dev present ($(basename "$(readlink -f "/sys/bus/pci/devices/$dev/driver")" 2>/dev/null || echo none))"
        responds "$dev" && ok "$dev answers config space" || bad "$dev is not responding - host reboot needed"
    else
        bad "$dev not found on the host"
    fi
done
echo "  GPU reset_method: $(cat "/sys/bus/pci/devices/$GPU/reset_method" 2>/dev/null || echo '<none>')"
if [ -x "$HOOKSCRIPT_LOCAL" ]; then ok "hookscript $HOOKSCRIPT_LOCAL"; else bad "hookscript missing (run 00-host-prep.sh)"; fi

printf '\n== Result ==\n%d ok, %d warnings, %d failures\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ] || { echo "Fix the failures above first."; exit 1; }

say "Detach the installer ISO"
if qm config "$VMID" | grep -q '^ide2:'; then
    qm set "$VMID" --delete ide2
    ok "ide2 removed"
else
    note "no ide2 entry"
fi
qm set "$VMID" --boot order=scsi0
ok "boot order -> scsi0"

say "Attach GPU + audio + hookscript"
qm set "$VMID" \
    --hookscript "$HOOKSCRIPT" \
    --hostpci0 "${GPU},pcie=1" \
    --hostpci1 "${AUDIO},pcie=1"
ok "hostpci0 = ${GPU},pcie=1 (single function, atomics)"
ok "hostpci1 = ${AUDIO},pcie=1 (audio, so vfio can reset the device)"

qm config "$VMID" | grep -E '^(machine|bios|efidisk0|cpu|sockets|cores|memory|balloon|scsihw|scsi0|net0|hostpci0|hostpci1|hookscript|vga|serial0):' | sed 's/^/  /'

cat <<EOF

== Next ==
  qm start $VMID
  bash 40-verify.sh          # host + guest checks

Expect:
  host, while running:  lspci -nnk -s $GPU   -> Kernel driver in use: vfio-pci
  host, after stop:     lspci -nnk -s $GPU   -> Kernel driver in use: amdgpu
  host log:            no "depends on group 33 which is not owned"
  guest:               dmesg | grep 'atomic ops is not supported'   (must be empty)

If the VM does not start and the task log says the device is not responding,
the card was left wedged by the previous run: reboot the host, then start it.
EOF
