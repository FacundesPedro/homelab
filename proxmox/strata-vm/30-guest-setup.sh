#!/usr/bin/env bash
# 30-guest-setup.sh - run INSIDE the Ubuntu 26.04 VM (VM 200) as root.
#
# From the Proxmox host:
#   ssh <user>@<vm-ip> 'sudo bash -s' < proxmox/strata-vm/30-guest-setup.sh
#
# Or copy it in and run: sudo bash 30-guest-setup.sh
#
# What it does: base packages, guest agent, optional ROCm, mmap sysctl, Strata
# checkout, the worker clamp and the systemd unit. It starts the interactive
# model setup in tmux; it does not download a model itself.
#
# ROCm is OPTIONAL. Strata's Linux package carries its own HIP runtime and
# prox-1 runs on the kernel amdgpu driver alone. Install the archive ROCm only
# if you also want rocminfo / PyTorch in this VM:
#   INSTALL_ROCM=1 sudo -E bash 30-guest-setup.sh
# Never install amdgpu-dkms: it does not build against kernel 7.0.

set -euo pipefail

STRATA_USER="${STRATA_USER:-${SUDO_USER:-strata}}"
STRATA_DIR="${STRATA_DIR:-/opt/Strata}"
INSTALL_ROCM="${INSTALL_ROCM:-0}"
WORKERS="${WORKERS:-13}"

say() { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash $0"; exit 1; }

say "Pre-flight"
. /etc/os-release
echo "  $PRETTY_NAME, kernel $(uname -r)"
if [ -e /dev/kfd ] && compgen -G '/dev/dri/renderD*' >/dev/null; then
    echo "  [ OK ] /dev/kfd and /dev/dri/renderD* present"
else
    echo "  [FAIL] no /dev/kfd or /dev/dri/renderD* - is the GPU attached and the VM started?"
    exit 1
fi
lspci -nnk -d 1002:744c | sed 's/^/  /'
if dmesg | grep -q 'atomic ops is not supported'; then
    echo "  [WARN] guest amdgpu reports no PCIe atomics; ROCm may fail (check the root port)"
else
    echo "  [ OK ] PCIe atomics enabled"
fi

say "Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    git build-essential curl ca-certificates tmux python3 python3-venv python3-pip \
    pkg-config procps jq qemu-guest-agent
systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || true

if [ "$INSTALL_ROCM" = "1" ]; then
    say "ROCm from the Ubuntu archive (no amdgpu-dkms)"
    apt-get install -y -qq rocm rocm-dev
    # Ubuntu 26.04 installs ROCm under /usr; Strata's build probes both.
    [ -e /opt/rocm ] || ln -s /usr /opt/rocm
    /usr/bin/rocminfo | grep -m1 'Name:.*gfx' || true
else
    say "ROCm: skipped (INSTALL_ROCM=0)"
fi

say "Guest amdgpu runtime PM"
# Disable BACO runtime suspend inside the guest. On a passed-through Navi 31
# the suspend/resume cycle can hang the host's PCIe link; keep the card in D0.
if grep -q 'amdgpu.runpm=0' /etc/default/grub; then
    echo "  amdgpu.runpm=0 already present"
else
    sed -i -E 's/^(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*)"$/\1 amdgpu.runpm=0"/' /etc/default/grub
    update-grub >/dev/null
    echo "  added amdgpu.runpm=0 (takes effect on the next guest reboot)"
fi

say "Kernel / VM sysctls"
cat >/etc/sysctl.d/90-strata.conf <<'EOF'
# mmap-heavy model loading (model packs, expert files)
vm.max_map_count = 1048576
EOF
sysctl --system >/dev/null
echo "  vm.max_map_count=$(sysctl -n vm.max_map_count)"

say "Groups"
usermod -aG render,video "$STRATA_USER" 2>/dev/null || true
id "$STRATA_USER" | sed 's/^/  /'

say "Strata source"
if [ -d "$STRATA_DIR/.git" ]; then
    git -C "$STRATA_DIR" pull --ff-only || echo "  (pull skipped, keeping the checkout)"
else
    git clone --depth 1 https://github.com/Niko1221/Strata "$STRATA_DIR"
fi

say "Worker clamp (PVE exposes no CPU threads=, guest reports $WORKERS-capable topology)"
cat >/usr/local/sbin/strata-fix-workers <<EOF
#!/usr/bin/env bash
# Enforce --pool-workers $WORKERS on the setup-generated run script.
# Above the physical-core count Strata is measurably slower (issue #3417).
set -euo pipefail
want=$WORKERS
found=0
for f in /opt/Strata/run-*.sh; do
    [ -e "\$f" ] || continue
    found=1
    if grep -q -- '--pool-workers' "\$f"; then
        sed -i -E "s/--pool-workers[= ]+[0-9]+/--pool-workers \$want/g" "\$f"
        echo "workers: \$f -> --pool-workers \$want"
    else
        echo "workers: WARNING \$f has no --pool-workers; set it to \$want by hand" >&2
    fi
done
[ "\$found" = 1 ] || echo "workers: no run-*.sh yet (setup.sh creates it)" >&2
exit 0
EOF
chmod 0755 /usr/local/sbin/strata-fix-workers

say "systemd unit (disabled until setup has run)"
cat >/etc/systemd/system/strata.service <<'EOF'
[Unit]
Description=Strata HIP inference engine (gfx1100, RX 7900 XT passthrough)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/Strata
# Helper threads use the vCPUs the 13 workers do not pin.
Environment=STRATA_AUX_CPUS=auto
# ROCm pinned host allocations for the expert arena.
LimitMEMLOCK=infinity
ExecStartPre=/usr/local/sbin/strata-fix-workers
ExecStart=/bin/bash -lc 'exec /opt/Strata/run-iq3_s.sh'
Restart=on-failure
RestartSec=10
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo "  /etc/systemd/system/strata.service written (not enabled)"

say "Start the interactive setup"
if tmux has-session -t strata-setup 2>/dev/null; then
    echo "  tmux session 'strata-setup' already exists"
else
    tmux new-session -d -s strata-setup \
        "cd $STRATA_DIR && ./setup.sh --backend hip; echo; echo 'Setup finished. Press Enter to close.'; read"
    echo "  started tmux session 'strata-setup'"
fi

cat <<EOF

== Next ==
  tmux attach -t strata-setup

  Setup choices (same as prox-1):
    - backend: HIP
    - model pack: IQ3_S (ISTA-DASLab)
    - context 128K, KV int8, MTP resident
    - let it pick low-RAM mode + CPU vision encoder on 20 GB
    - setup starts its own engine at the end: stop it (Ctrl+C) BEFORE
      enabling the service, or two engines share 52 GiB and get OOM-killed

  Then:
    sudo /usr/local/sbin/strata-fix-workers      # forces --pool-workers $WORKERS
    sudo systemctl enable --now strata
    systemctl status strata --no-pager

  If the run script has a different name than run-iq3_s.sh:
    ls /opt/Strata/run-*.sh
    sudo systemctl edit strata                   # override ExecStart
EOF
