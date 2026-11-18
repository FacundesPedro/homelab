#!/usr/bin/env bash
# ram-monitor.sh - real memory (PVE UI value), page cache, engine RSS, host/VRAM/GPU.
# Run on the Proxmox host as root:
#   SAMPLES=30 INTERVAL=2 bash ram-monitor.sh
#
# PVE's UI/pvesh `mem` is memory.current - memory.stat.file (page cache excluded).
# memory.current alone looks ~14 GiB higher because it counts the reclaimable cache.
set -u

CTID="${CTID:-121}"
NODE="${NODE:-$(hostname -s)}"
SAMPLES="${SAMPLES:-20}"
INTERVAL="${INTERVAL:-2}"
GPU_PCI="${GPU_PCI:-05:00.0}"
GPU_PCI="${GPU_PCI:-05:00.0}"
H=""
for h in /sys/class/hwmon/hwmon*; do
    [ "$(cat "$h/name" 2>/dev/null)" = amdgpu ] && H="$h"
done
DEVPATH=$(readlink -f "/sys/bus/pci/devices/0000:$GPU_PCI" 2>/dev/null || true)
V=""
for c in /sys/class/drm/card[0-9]*; do
    [ -e "$c/device" ] || continue
    [ "$(readlink -f "$c/device")" = "$DEVPATH" ] && V="$c/device"
done
V=${V:-/sys/class/drm/card0/device}

for _ in $(seq 1 "$SAMPLES"); do
    J=$(pvesh get "/nodes/$NODE/lxc/$CTID/status/current" --output-format json 2>/dev/null)
    read -r MEM MAX SWAP <<<"$(printf '%s' "$J" | python3 -c '
import sys, json
d = json.load(sys.stdin)
print(d.get("mem", 0), d.get("maxmem", 0), d.get("swap", 0))' 2>/dev/null || echo "0 0 0")"
    CUR=$(cat "/sys/fs/cgroup/lxc/$CTID/memory.current" 2>/dev/null || echo 0)
    STAT=$(cat "/sys/fs/cgroup/lxc/$CTID/memory.stat" 2>/dev/null || true)
    ANON=$(awk '/^anon /{print $2}' <<<"$STAT")
    FILE=$(awk '/^file /{print $2}' <<<"$STAT")
    INACT=$(awk '/^inactive_file /{print $2}' <<<"$STAT")
    REAL=$((CUR - FILE))
    ERSS=$(pct exec "$CTID" -- ps -eo rss,comm 2>/dev/null | awk '/strata-host/{print $1; exit}')
    ERSS=${ERSS:-0}
    CFREE=$(pct exec "$CTID" -- free -m 2>/dev/null | awk '/^Mem:/{print $4" / "$7}')
    HFREE=$(free -m | awk '/^Mem:/{print $4" / "$7}')
    VRAM=$(cat "$V/mem_info_vram_used" 2>/dev/null || echo 0)
    JT=$(cat "$H/temp2_input" 2>/dev/null || echo 0)
    PW=$(cat "$H/power1_average" 2>/dev/null || echo 0)
    PCT=$(awk -v m="$MEM" -v x="$MAX" 'BEGIN{printf "%.1f", (x ? m * 100 / x : 0)}')
    printf '%s pve_mem=%d MiB (%s%%) anon=%d MiB file_cache=%d MiB real=%d MiB engine_rss=%d MiB ct_free=%s MiB host_free=%s MiB vram=%d MiB junction=%dC power=%dW\n' \
        "$(date +%T)" \
        "$((MEM / 1048576))" "$PCT" \
        "$((ANON / 1048576))" "$((FILE / 1048576))" "$((REAL / 1048576))" \
        "$((ERSS / 1024))" \
        "$CFREE" "$HFREE" \
        "$((VRAM / 1048576))" \
        "$((JT / 1000))" "$((PW / 1000000))"
    sleep "$INTERVAL"
done
