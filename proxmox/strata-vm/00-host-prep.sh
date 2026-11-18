#!/usr/bin/env bash
# 00-host-prep.sh - prox-2: kernel flags, vfio modules, GPU handoff hookscript.
#
# Run on the Proxmox host as root:
#   bash 00-host-prep.sh              # apply
#   DRY_RUN=1 bash 00-host-prep.sh    # show what would change
#
# Deliberately NOT done (see README):
#   - no `blacklist amdgpu`            the host must own the card between VM runs
#   - no `options vfio-pci ids=...`    PVE binds it per VM start, after the hook
#   - no vendor-reset                  there is no Navi 31 support
#   - no pcie_acs_override             the GPU already has its own IOMMU group
#   - no initcall_blacklist=sysfb_init only needed when vfio binds at boot
#
# One reboot is required afterwards.

set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
GPU="${GPU:-0000:05:00.0}"
GRUB_FILE=/etc/default/grub
CMDLINE_WANT="${CMDLINE_WANT:-iommu=pt pcie_aspm=off}"
SNIPPET_DIR="${SNIPPET_DIR:-/mnt/nvme/snippets}"
HOOKSCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/strata-gpu-handoff.sh"
BACKUP_DIR="/root/proxmox-prep-$(date +%Y%m%d-%H%M%S)"

pass=0 warn=0 fail=0
ok()   { printf '  [ OK ] %s\n' "$*"; pass=$((pass+1)); }
note() { printf '  [WARN] %s\n' "$*"; warn=$((warn+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; fail=$((fail+1)); }
say()  { printf '\n== %s ==\n' "$*"; }
run()  { if [ "$DRY_RUN" = "1" ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

[ "$(id -u)" -eq 0 ] || { echo "run as root on the Proxmox host"; exit 1; }
command -v qm >/dev/null || { echo "qm not found - is this the Proxmox host?"; exit 1; }

say "Pre-flight"
pveversion | sed -n '1p' | sed 's/^/  /'
echo "  kernel: $(uname -r)"
if [ -e "/sys/bus/pci/devices/$GPU" ]; then
    ok "GPU $GPU present: $(lspci -nn -s "$GPU" | cut -d' ' -f2-)"
else
    bad "GPU $GPU not found"; exit 1
fi
if lspci -nnk -s "$GPU" | grep -q 'Kernel driver in use: amdgpu'; then
    ok "host owns the card via amdgpu (required by the handoff design)"
else
    bad "amdgpu is not in use on $GPU; check /etc/modprobe.d and the initramfs"
fi
[ -d "/sys/kernel/iommu_groups/$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU/iommu_group")")" ] \
    && ok "IOMMU is active" || bad "no IOMMU group for $GPU"
GROUPMATES=$(ls "/sys/bus/pci/devices/$GPU/iommu_group/devices/" | grep -v "^$(basename "$GPU")$" || true)
if [ -z "$GROUPMATES" ]; then
    ok "GPU is alone in its IOMMU group"
else
    note "GPU shares its group with: $GROUPMATES"
fi
findmnt -no TARGET /mnt/nvme >/dev/null && ok "/mnt/nvme is mounted" || bad "/mnt/nvme is not mounted"
[ -x "$HOOKSCRIPT_SRC" ] || chmod 0755 "$HOOKSCRIPT_SRC" 2>/dev/null || true
[ -f "$HOOKSCRIPT_SRC" ] && ok "hookscript source found" || { bad "missing $HOOKSCRIPT_SRC"; exit 1; }

[ "$fail" -eq 0 ] || { printf '\nFix the failures above first; nothing was changed.\n'; exit 1; }

say "Backup"
run mkdir -p "$BACKUP_DIR"
for f in "$GRUB_FILE" /etc/modprobe.d /etc/modules-load.d; do
    run cp -a "$f" "$BACKUP_DIR"/ 2>/dev/null || true
done
echo "  backup: $BACKUP_DIR"

say "GRUB command line"
CURRENT=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/\1/p' "$GRUB_FILE")
CURRENT=${CURRENT:-}
NEW=$CURRENT
for flag in $CMDLINE_WANT; do
    case " $NEW " in
        *" $flag "*) ;;
        *) NEW="${NEW:+$NEW }$flag" ;;
    esac
done
echo "  now:  \"$CURRENT\""
echo "  want: \"$NEW\""
if [ "$NEW" = "$CURRENT" ]; then
    ok "kernel flags already present"
else
    [ "$DRY_RUN" = "1" ] || sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW\"|" "$GRUB_FILE"
    if [ "$DRY_RUN" = "1" ]; then
        echo "  would rewrite GRUB_CMDLINE_LINUX_DEFAULT"
    else
        grep -n '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^/  /'
        ok "GRUB_CMDLINE_LINUX_DEFAULT updated"
    fi
fi
if [ -f /etc/kernel/cmdline ]; then
    note "systemd-boot host: /etc/kernel/cmdline exists - mirror the flags there and run proxmox-boot-tool refresh"
fi
if [ "$DRY_RUN" = "1" ]; then
    echo "  would run: update-grub"
else
    update-grub >/dev/null && ok "update-grub" || bad "update-grub failed"
fi

say "VFIO modules at boot"
MODFILE=/etc/modules-load.d/vfio.conf
if [ -f "$MODFILE" ] && diff -q <(printf 'vfio\nvfio_iommu_type1\nvfio_pci\n') "$MODFILE" >/dev/null; then
    ok "$MODFILE already correct"
else
    if [ "$DRY_RUN" = "1" ]; then
        echo "  would write $MODFILE"
    else
        printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' >"$MODFILE"
        ok "$MODFILE written"
    fi
fi
if [ "$DRY_RUN" = "1" ]; then
    echo "  would run: update-initramfs -u -k all"
else
    update-initramfs -u -k all >/dev/null && ok "update-initramfs" || bad "update-initramfs failed"
fi

say "Hookscript on the nvme storage (snippets content)"
run mkdir -p "$SNIPPET_DIR"
if [ "$DRY_RUN" = "1" ]; then
    echo "  would install $SNIPPET_DIR/$(basename "$HOOKSCRIPT_SRC")"
else
    install -m 0755 "$HOOKSCRIPT_SRC" "$SNIPPET_DIR/$(basename "$HOOKSCRIPT_SRC")"
    ok "installed $SNIPPET_DIR/$(basename "$HOOKSCRIPT_SRC")"
fi
pvesm status 2>/dev/null | awk '$1=="nvme"{print "  nvme: "$2" "$3" "$6" KiB free"}'

printf '\n== Result ==\n%d ok, %d warnings, %d failures\n' "$pass" "$warn" "$fail"
[ "$fail" -eq 0 ] || { echo "Fix the failures above first."; exit 1; }

if [ "$DRY_RUN" = "1" ]; then
    echo
    echo "DRY_RUN=1: nothing was changed."
    exit 0
fi

cat <<EOF

Next:
  1. reboot the host:   reboot
  2. after it is back:
       cat /proc/cmdline                     # expect iommu=pt pcie_aspm=off
       lsmod | grep vfio                     # expect vfio, vfio_iommu_type1, vfio_pci
       lspci -nnk -s $GPU                    # still amdgpu
  3. then create the VM:  bash 10-create-vm.sh

The card stays on amdgpu until VM 200 starts. That is intentional.
EOF
