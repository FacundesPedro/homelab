#!/usr/bin/env bash
# 20-verify-strata.sh - verify GPU access, service health and thread placement.
# Run on the Proxmox host as root.
set -euo pipefail

CTID="${CTID:-121}"
STRATA_DIR="${STRATA_DIR:-/opt/Strata}"
API="${API:-http://127.0.0.1:8080}"
GPU_PCI="${GPU_PCI:-05:00.0}"
DEVPATH=$(readlink -f "/sys/bus/pci/devices/0000:$GPU_PCI")
CARD=""
for c in /sys/class/drm/card[0-9]*; do
  [ -e "$c/device" ] || continue
  [ "$(readlink -f "$c/device")" = "$DEVPATH" ] && CARD=$(basename "$c")
done
CARD_NODE="/dev/dri/${CARD:-card0}"

pass=0 warn=0 fail=0
ok()   { printf '  [ OK ] %s\n' "$*"; pass=$((pass+1)); }
note() { printf '  [WARN] %s\n' "$*"; warn=$((warn+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
section() { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root on the Proxmox host"; exit 1; }

section "Host GPU"
if lspci -nnk -s "$GPU_PCI" | grep -q 'Kernel driver in use: amdgpu'; then
  ok "$GPU_PCI bound to amdgpu"
else
  bad "$GPU_PCI not bound to amdgpu"
fi
for node in /dev/kfd /dev/dri/renderD128 "$CARD_NODE"; do
  [ -e "$node" ] && ok "$node present" || bad "$node missing"
done

section "Container $CTID"
if ! pct status "$CTID" >/dev/null 2>&1; then
  bad "CT $CTID does not exist"
  printf '\n== Result ==\n%d ok, %d warnings, %d failures\n' "$pass" "$warn" "$fail"
  exit 1
fi
STATE=$(pct status "$CTID" | awk '{print $2}')
echo "  state: $STATE"
if [ "$STATE" != "running" ]; then
  note "CT is stopped; start it with: bash 30-strata-control.sh start"
  printf '\n== Result ==\n%d ok, %d warnings, %d failures\n' "$pass" "$warn" "$fail"
  exit 1
fi
ok "CT running"
pct exec "$CTID" -- bash -c 'test -r /dev/kfd && test -w /dev/dri/renderD128' \
  && ok "device nodes readable/writable inside CT" \
  || bad "cannot access /dev/kfd or /dev/dri/renderD128 inside CT"

section "Service"
if pct exec "$CTID" -- systemctl is-active --quiet strata; then
  ok "strata.service active"
elif pct exec "$CTID" -- pgrep -f "$STRATA_DIR" >/dev/null 2>&1; then
  note "strata process running outside systemd (unit not enabled yet)"
else
  bad "strata is not running"
fi

section "API"
if pct exec "$CTID" -- curl -fsS --max-time 5 "$API/health" >/dev/null 2>&1; then
  ok "GET $API/health"
else
  note "health endpoint not answering (model may still be loading)"
fi
pct exec "$CTID" -- curl -fsS --max-time 5 "$API/v1/models" 2>/dev/null | head -c 300 || true
echo

section "Thread placement"
PHYS=$(lscpu -p=Core 2>/dev/null | grep -v '^#' | sort -u | wc -l | tr -d ' ')
LOGICAL=$(nproc)
EXPECTED=$((PHYS > 1 ? PHYS - 1 : 1))
echo "  host: $PHYS physical cores, $LOGICAL threads; expected workers: $EXPECTED"
LOG=$(pct exec "$CTID" -- journalctl -u strata -n 500 --no-pager 2>/dev/null || true)
if [ -z "$LOG" ]; then
  LOG=$(pct exec "$CTID" -- bash -c "tail -n 500 $STRATA_DIR/*.log" 2>/dev/null || true)
fi
WORKERS=$(printf '%s\n' "$LOG" | grep -oE 'CPU pool: [0-9]+ workers|\([0-9]+ workers' | grep -oE '[0-9]+' | head -1 || true)
if [ -n "${WORKERS:-}" ]; then
  if [ "$WORKERS" -le "$PHYS" ]; then
    ok "engine uses $WORKERS workers (<= $PHYS physical cores)"
  else
    bad "engine uses $WORKERS workers for $PHYS physical cores: raise is a measured slowdown"
  fi
  printf '%s\n' "$LOG" | grep 'CPU workers on logical processors' | tail -1 | sed 's/^/  /' || true
else
  note "worker line not found yet (engine still starting?)"
fi
if printf '%s\n' "$LOG" | grep -q 'strata cpu pool: warning'; then
  warn "engine printed a pool-worker warning:"
  printf '%s\n' "$LOG" | grep 'strata cpu pool: warning' | tail -2 | sed 's/^/  /'
fi

section "Memory inside CT"
pct exec "$CTID" -- free -h | sed 's/^/  /'

printf '\n== Result ==\n%d ok, %d warnings, %d failures\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ] || exit 1
