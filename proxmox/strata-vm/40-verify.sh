#!/usr/bin/env bash
# 40-verify.sh - read-only checks for the Strata VM and the GPU handoff.
#
#   bash 40-verify.sh            # host + guest checks
#   CYCLE=1 bash 40-verify.sh    # also stop and start the VM once (the real test)
#
# The cycle test uses a clean ACPI shutdown. If the card does not come back on
# amdgpu afterwards, the host needs a reboot - that is the Navi 31 reset bug,
# not a configuration mistake.

set -uo pipefail

VMID="${VMID:-200}"
GPU="${GPU:-0000:05:00.0}"
API="${API:-http://127.0.0.1:8080}"
CYCLE="${CYCLE:-0}"

pass=0 warn=0 fail=0
ok()   { printf '  [ OK ] %s\n' "$*"; pass=$((pass+1)); }
note() { printf '  [WARN] %s\n' "$*"; warn=$((warn+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
say()  { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root on the Proxmox host"; exit 1; }

driver() {
    local d
    d=$(readlink -f "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null) || { echo none; return; }
    basename "$d"
}

guest() {
    # Run a command in the guest through qemu-guest-agent, print its stdout.
    qm guest exec "$VMID" --timeout 30 -- "$@" 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.stdout.write(d.get("out-data", ""))
sys.exit(d.get("exitcode", 1))
'
}

say "Host boot configuration"
tr '\0' ' ' </proc/cmdline | grep -q 'iommu=pt' && ok "iommu=pt" || bad "iommu=pt missing from /proc/cmdline"
tr '\0' ' ' </proc/cmdline | grep -q 'pcie_aspm=off' && ok "pcie_aspm=off" || note "pcie_aspm=off missing"
for m in vfio vfio_iommu_type1 vfio_pci; do
    lsmod | grep -q "^$m " && ok "$m loaded" || bad "$m not loaded"
done

say "GPU"
if [ -e "/sys/bus/pci/devices/$GPU" ]; then
    ok "$GPU present, driver=$(driver)"
else
    bad "$GPU missing from the bus"
fi
GROUP=$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU/iommu_group" 2>/dev/null)")
MATES=$(ls "/sys/bus/pci/devices/$GPU/iommu_group/devices/" 2>/dev/null | grep -v "^$(basename "$GPU")$" || true)
[ -z "$MATES" ] && ok "IOMMU group $GROUP is exclusive" || note "group $GROUP also holds: $MATES"
echo "  reset_method: $(cat "/sys/bus/pci/devices/$GPU/reset_method" 2>/dev/null || echo '<none>')"

say "VM $VMID"
if ! qm status "$VMID" >/dev/null 2>&1; then
    bad "VM $VMID does not exist"
    printf '\n== Result ==\n%d ok, %d warnings, %d failures\n' "$pass" "$warn" "$fail"
    exit 1
fi
STATE=$(qm status "$VMID" | awk '{print $2}')
echo "  state: $STATE"
CONF=$(qm config "$VMID")
for want in '^machine: q35' '^bios: ovmf' '^cpu: host$' '^balloon: 0$' '^hostpci0:.*pcie=1' '^hostpci1:.*pcie=1' '^hookscript:'; do
    printf '%s\n' "$CONF" | grep -qE "$want" && ok "config: ${want#^}" || bad "config missing: $want"
done
printf '%s\n' "$CONF" | grep -qE '^hostpci0:.*05:00\.0' \
    && ok "GPU passed as a single function (05:00.0)" \
    || note "hostpci0 is not 05:00.0 - multifunction passthrough strips PCIe atomics"
printf '%s\n' "$CONF" | grep -qE '^hostpci1:.*05:00\.1' \
    && ok "HDMI audio passed separately (group 33 owned, reset allowed)" \
    || note "hostpci1 missing - vfio-pci will refuse to reset the GPU"
if [ "$STATE" = "running" ]; then
    [ "$(driver)" = "vfio-pci" ] && ok "host driver is vfio-pci" || bad "host driver is $(driver), expected vfio-pci"
else
    [ "$(driver)" = "amdgpu" ] && ok "host driver is amdgpu (card recovered)" || bad "host driver is $(driver), expected amdgpu"
fi

say "Hookscript log (last 6)"
if [ -f /var/log/strata-gpu-handoff.log ]; then
    tail -n 6 /var/log/strata-gpu-handoff.log | sed 's/^/  /'
else
    note "no /var/log/strata-gpu-handoff.log yet"
fi

if [ "$STATE" = "running" ]; then
    say "Guest"
    if OUT=$(guest /bin/sh -c 'lspci -nnk -d 1002:744c' 2>/dev/null) && [ -n "$OUT" ]; then
        ok "GPU visible in the guest"
        printf '%s\n' "$OUT" | sed 's/^/  /'
    else
        bad "guest agent not answering, or the GPU is not visible"
    fi
    if guest /bin/sh -c 'test -e /dev/kfd && ls /dev/dri/renderD* >/dev/null'; then
        ok "/dev/kfd and render node present"
    else
        bad "/dev/kfd or render node missing"
    fi
    if guest /bin/sh -c 'dmesg | grep -q "atomic ops is not supported"'; then
        bad "guest reports no PCIe atomics - check the root port / multifunction form"
    else
        ok "no 'atomic ops is not supported' in the guest"
    fi
    if guest /bin/sh -c "curl -fsS --max-time 5 $API/health >/dev/null"; then
        ok "Strata API $API/health"
    else
        note "Strata API not answering (model still loading, or service not enabled)"
    fi
    if guest systemctl is-active --quiet strata; then ok "strata.service active"; else note "strata.service not active"; fi
    WORKERS=$(guest /bin/sh -c "journalctl -u strata -n 500 --no-pager 2>/dev/null | grep -oE '[0-9]+ workers' | head -1" || true)
    if [ -n "${WORKERS:-}" ]; then
        echo "  engine reports: $WORKERS"
        N=$(printf '%s' "$WORKERS" | grep -oE '[0-9]+')
        [ "$N" -le 13 ] && ok "worker count $N <= 13" || bad "worker count $N > 13 (Strata issue #3417)"
    else
        note "worker line not found yet"
    fi
fi

if [ "$CYCLE" = "1" ]; then
    say "Cycle test: clean shutdown -> amdgpu -> start"
    [ "$STATE" = "running" ] || { bad "VM must be running for the cycle test"; }
    if [ "$STATE" = "running" ]; then
        qm shutdown "$VMID" --timeout 180 >/dev/null 2>&1 || true
        for _ in $(seq 1 60); do
            [ "$(qm status "$VMID" | awk '{print $2}')" = "stopped" ] && break
            sleep 3
        done
        sleep 8
        echo "  after shutdown, host driver: $(driver)"
        [ "$(driver)" = "amdgpu" ] && ok "card returned to amdgpu" || bad "card did not return to amdgpu - reboot the host"
        qm start "$VMID" >/dev/null 2>&1 || true
        for _ in $(seq 1 60); do
            guest /bin/true >/dev/null 2>&1 && break
            sleep 3
        done
        echo "  after start, host driver: $(driver)"
        [ "$(driver)" = "vfio-pci" ] && ok "card handed back to vfio-pci" || bad "card not on vfio-pci"
        guest /bin/sh -c 'test -e /dev/kfd' && ok "guest sees /dev/kfd again" || bad "guest lost the GPU"
    fi
fi

printf '\n== Result ==\n%d ok, %d warnings, %d failures\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ] || exit 1
