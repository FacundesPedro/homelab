#!/usr/bin/env bash
# strata-gpu-handoff.sh - Proxmox hookscript for VM 200 ("strata").
#
#   qm set 200 --hookscript nvme:snippets/strata-gpu-handoff.sh
#
# The RX 7900 XT (Navi 31) does not reset cleanly: when vfio-pci releases it,
# the kernel's only available reset is a secondary bus reset ("reset_method:
# bus"), and that is the reset that leaves RDNA3 wedged. AMD does not support
# passthrough for this card and vendor-reset has no Navi 31 code.
#
# The one thing that does work: let amdgpu own the card whenever the VM is not
# running. amdgpu can re-initialise the ASIC; vfio-pci cannot. So:
#
#   pre-start : if a previous stop left a function on vfio-pci, give it back
#               to its host driver first, then keep the GPU in D0 so it does
#               not fall into D3cold while driverless.
#   post-stop : hand both functions back to their host drivers.
#
# Both functions are managed. The GPU is passed as its own single-function
# hostpci (so QEMU advertises PCIe AtomicOp completers for ROCm), and the HDMI
# audio is passed as a second hostpci. That keeps the GPU single-function while
# letting the VM own group 33 - otherwise vfio-pci refuses to reset the GPU:
#   "Cannot reset device 0000:05:00.0, depends on group 33 which is not owned"
#
# PVE binds the functions to vfio-pci itself after the pre-start hook (see
# QemuServer.pm: pre-start at 5451, prepare_pci_devices at 5523), so this script
# never binds vfio-pci.
#
# Runs as root on the host. PVE passes: $1 = vmid, $2 = phase.

set -uo pipefail

GPU="${GPU:-0000:05:00.0}"
AUDIO="${AUDIO:-0000:05:00.1}"
GPU_HOST_DRIVER="${GPU_HOST_DRIVER:-amdgpu}"
AUDIO_HOST_DRIVER="${AUDIO_HOST_DRIVER:-snd_hda_intel}"
LOG=/var/log/strata-gpu-handoff.log
phase="${2:-}"

log() { printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2; }

driver() {
    local dev=$1 d
    d=$(readlink -f "/sys/bus/pci/devices/$dev/driver" 2>/dev/null) || return 0
    basename "$d"
}

unbind() {
    local dev=$1 drv=$2 d="/sys/bus/pci/drivers/$2"
    [ -e "$d/unbind" ] || return 0
    echo "$dev" >"$d/unbind" 2>/dev/null || true
}

bind() {
    local dev=$1 drv=$2 d="/sys/bus/pci/drivers/$2"
    [ -e "$d/bind" ] || return 0
    echo "$dev" >"$d/bind" 2>/dev/null || true
}

responds() {
    # A device that dropped off the bus answers every config read with 0xff.
    local dev=$1 header
    header=$(dd if="/sys/bus/pci/devices/$dev/config" bs=1 skip=14 count=1 2>/dev/null |
        od -An -tu1 | tr -d ' ')
    [ -n "$header" ] && [ "$header" != "255" ]
}

recover() {
    local dev=$1 hostdrv=$2
    [ "$(driver "$dev")" = "vfio-pci" ] || return 0
    log "  $dev left on vfio-pci, recovering through $hostdrv"
    unbind "$dev" vfio-pci
    sleep 2
    bind "$dev" "$hostdrv"
    sleep 2
}

case "$phase" in
    pre-start)
        recover "$GPU" "$GPU_HOST_DRIVER"
        recover "$AUDIO" "$AUDIO_HOST_DRIVER"

        # Keep the GPU in D0 across the driverless window between amdgpu
        # unbinding and vfio-pci binding. Without this the kernel can drop it
        # into D3cold and PVE aborts with "device is not responding".
        echo 0 >"/sys/bus/pci/devices/$GPU/d3cold_allowed" 2>/dev/null || true
        echo on >"/sys/bus/pci/devices/$GPU/power/control" 2>/dev/null || true

        if responds "$GPU" && responds "$AUDIO"; then
            log "pre-start: gpu=$(driver "$GPU") audio=$(driver "$AUDIO") d3cold=$(cat "/sys/bus/pci/devices/$GPU/d3cold_allowed" 2>/dev/null) ok"
        else
            log "pre-start: WARNING a function is not answering config space (host reboot may be needed)"
        fi
        ;;
    post-stop)
        # Give QEMU/vfio time to close before touching the drivers.
        sleep 5
        unbind "$GPU" vfio-pci
        unbind "$AUDIO" vfio-pci
        sleep 2
        bind "$GPU" "$GPU_HOST_DRIVER"
        bind "$AUDIO" "$AUDIO_HOST_DRIVER"
        sleep 3
        if responds "$GPU"; then
            log "post-stop: gpu=$(driver "$GPU") audio=$(driver "$AUDIO") ok"
        else
            log "post-stop: WARNING GPU did not come back; next start may need a host reboot"
        fi
        ;;
    *)
        # post-start / pre-stop / post-pci-prepare: nothing to do.
        ;;
esac

exit 0
