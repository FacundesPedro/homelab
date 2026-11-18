#!/usr/bin/env bash
# 00-check-host.sh - read-only audit before creating the Strata container.
# Run on the Proxmox host as root:  bash 00-check-host.sh
set -euo pipefail

STORAGE="${STORAGE:-local-lvm}"
MODEL_NEED_GB="${MODEL_NEED_GB:-110}"
GPU_PCI="${GPU_PCI:-05:00.0}"

pass=0 warn=0 fail=0
ok()   { printf '  [ OK ] %s\n' "$*"; pass=$((pass+1)); }
note() { printf '  [WARN] %s\n' "$*"; warn=$((warn+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
section() { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root on the Proxmox host"; exit 1; }

section "Proxmox / kernel"
pveversion 2>/dev/null | sed -n '1p'
echo "  kernel: $(uname -r)"
echo "  cpu:    $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2}')"
PHYS=$(lscpu -p=Core 2>/dev/null | grep -v '^#' | sort -u | wc -l | tr -d ' ')
LOGICAL=$(nproc)
echo "  cores:  $LOGICAL threads, $PHYS physical cores"
echo "  memory: $(free -h | awk '/^Mem:/{print $2" total, "$7" available"}')"

section "GPU / driver"
if lspci -nnk -s "$GPU_PCI" | grep -q 'Kernel driver in use: amdgpu'; then
  ok "$GPU_PCI bound to amdgpu (device sharing is ready)"
else
  bad "$GPU_PCI is not bound to amdgpu: $(lspci -nnk -s "$GPU_PCI" | tail -1)"
fi
lspci -nn -s "$GPU_PCI" | sed 's/^/  /'

section "Device nodes"
for node in /dev/kfd /dev/dri/renderD128 /dev/dri/card1; do
  if [ -e "$node" ]; then
    stat -c '  %n  mode=%a owner=%U:%G' "$node"
  else
    bad "$node missing"
  fi
done
RENDER_GID=$(getent group render | cut -d: -f3 || true)
VIDEO_GID=$(getent group video | cut -d: -f3 || true)
ok "container-side GIDs will be resolved inside the CT (host: render=${RENDER_GID:-?} video=${VIDEO_GID:-?})"

section "Thread placement"
echo "  Strata default workers: $((PHYS > 1 ? PHYS - 1 : 1)) (one per physical core, host core excluded)"
echo "  never set --pool-workers above $PHYS; above that Strata measured ~37% slower (issue #3417)"
echo "  the unit sets STRATA_AUX_CPUS=auto so helper threads use the SMT siblings"

section "Memory / swap"
free -h | sed 's/^/  /'
swapon --show 2>/dev/null | grep -q . && ok "swap active" || note "no active swap"

section "Storage"
pvesm status | sed 's/^/  /'
AVAIL_GB=$(pvesm status 2>/dev/null | awk -v s="$STORAGE" '$1==s{printf "%d", $6/1048576}')
AVAIL_GB=${AVAIL_GB:-0}
if [ "$AVAIL_GB" -ge "$MODEL_NEED_GB" ]; then
  ok "$STORAGE has ${AVAIL_GB} GiB free (IQ3_S needs ~${MODEL_NEED_GB} GiB)"
else
  bad "$STORAGE has only ${AVAIL_GB} GiB free, IQ3_S needs ~${MODEL_NEED_GB} GiB"
fi
lsblk -ndo NAME,SIZE,ROTA,MODEL | awk '$3==0{print "  SSD: "$1" "$2" "$4}'

section "Templates and guests"
if ls /var/lib/vz/template/cache/*.tar.* >/dev/null 2>&1; then
  ls -1 /var/lib/vz/template/cache/ | sed 's/^/  /'
else
  echo "  no downloaded templates (the create script downloads Debian 13)"
fi
pct list 2>/dev/null | sed 's/^/  /'

printf '\n== Result ==\n%d ok, %d warnings, %d failures\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ] || { echo "Fix the failures above first."; exit 1; }
echo "Host is ready for the Strata LXC."
