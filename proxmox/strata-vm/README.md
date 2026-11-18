# Strata in a VM on prox-2 — RX 7900 XT passthrough

> **Superseded (2026-11-16).** This VM was reverted. prox-2 now runs Strata in
> `proxmox/strata-lxc/` (CT 121, Debian 13, device sharing, NVMe rootfs). The
> VFIO findings below — the audio-group reset dependency and the pinned guest
> RAM — are kept as the record of why the VM path was abandoned.

**Status: files only, nothing applied to prox-2 yet.** Stage 0 (read-only audit)
is done; the scripts below are the proposed change.

Strata runs in an **Ubuntu 26.04 Server VM on the 477 GB NVMe**, with the
**RX 7900 XT passed through via VFIO**. The alternative already proven on
prox-1 (LXC device sharing) is deliberately not used here.

| | |
|---|---|
| Host | prox-2, `192.168.3.56`, PVE 9.2.28, kernel `7.0.14-29-pve` |
| VM | `200` / `strata`, q35 + OVMF, 24 vCPU, 52 GiB, 380 GB qcow2 on `nvme` |
| GPU | ASRock RX 7900 XT, Navi 31 `1002:744c`, `05:00.0`, alone in IOMMU group 32 |
| Guest | Ubuntu 26.04.1, inbox `amdgpu`, no `amdgpu-dkms` |
| Iso | `local:iso/ubuntu-26.04.1-live-server-amd64.iso` (already downloaded) |

---

## The finding that shapes everything: the Navi 31 reset bug

This is not the usual passthrough guide. The RX 7900 XT does not reset cleanly,
and that is a hardware/firmware property, not a Proxmox bug.

Evidence gathered for this host and from current sources:

| Evidence | Detail |
|---|---|
| AMD support case | An RX 7900 XTX owner was told *"PCI Passthrough is unfortunately not supported in any configuration for the 7900 XTX"* (quoted on the Proxmox forum, Jan 2026) |
| `vendor-reset` | Upstream has **no Navi 31 support** (issue #97 still open). A fork whose README claims "Navi 31 support" has **no `0x744c` in its device table and no `navi31.c`** — the claim is false |
| This host | The kernel exposes **only `reset_method: bus`**. That is the secondary bus reset, i.e. exactly the reset that wedges RDNA3 |
| Repro | First start after a host boot works. Guest reboots usually work. **VM stop → start can leave the card in a state only a host reboot recovers** |

### What actually works

Let `amdgpu` own the card whenever the VM is not running, and hand it over per
VM run with a hookscript. `amdgpu` can re-initialise the ASIC; `vfio-pci`
cannot. This is the pattern the 2025–2026 Proxmox threads converged on for
RDNA3/RDNA4 (the old advice — pre-bind `vfio-pci` at boot and blacklist
`amdgpu` — makes the failure permanent instead of recoverable).

```
host boot ──► amdgpu ──┐
                       ├─ pre-start  : if leftover vfio-pci → amdgpu, lock D0
VM start  ─────────────┘
                       └─ PVE binds vfio-pci (after pre-start hook)
VM stop   ──► post-stop : unbind vfio-pci, bind amdgpu
```

### What you give up (accept or choose the LXC path)

- No live migration, no VM-state snapshots.
- A stop/start cycle **may** still need a host reboot. The hookscript makes it
  the exception, not the rule.
- The host has no iGPU and no BMC: while the VM runs, the local console is
  gone. Access is SSH / the Proxmox UI. A wedged card may need a physical
  power cycle.

If that trade is not acceptable, `proxmox/gpu-passthrough/` already runs
Strata on the same GPU/CPU as an LXC with no reboot risk.

---

## Why these choices

| Choice | Why |
|---|---|
| GPU as `05:00.0` on its own root port, **not** `05:00` (all functions) | QEMU only advertises PCIe AtomicOp *completer* support for **single-function** devices. `05:00` makes the GPU multifunction and strips atomics; the guest logs `PCIE atomic ops is not supported` and ROCm fails with *"operation cannot be performed in the present state"* |
| Audio as a **second** `hostpci1: 05:00.1` | The VM must own IOMMU group 33 as well, or vfio-pci refuses to reset the GPU: `Cannot reset device 0000:05:00.0, depends on group 33 which is not owned`. Separate root ports keep the GPU single-function *and* let the reset cover the whole device |
| `amdgpu` owns the card at boot | The only recoverable state for a Navi 31. No `blacklist amdgpu`, no `vfio-pci ids=` |
| Hookscript instead of pre-binding | PVE already binds `vfio-pci` at VM start (`prepare_pci_devices` runs **after** the `pre-start` hook). The hook only has to recover and to give the card back |
| No `vendor-reset` | No Navi 31 implementation exists |
| No `pcie_acs_override` | The GPU already has its own IOMMU group; ACS override weakens isolation for no benefit |
| No `initcall_blacklist=sysfb_init` | Only needed when `vfio-pci` binds at boot. Here `amdgpu` takes the framebuffer and releases it on unbind |
| q35 + OVMF | The only sane PCIe topology for passthrough; also required for the atomic completer path |
| `--pool-workers 13` | Proxmox has **no `threads=`** (`-smp` is sockets × cores). The guest sees 24 cores; Strata would default to 23 and is ~37% slower above the physical core count (its issue #3417) |
| No host-level vCPU pinning | Single socket / single NUMA, and Strata already pins its 13 workers inside the guest. PVE has no per-vCPU affinity; a cpuset or `taskset` on the whole QEMU process only removes the scheduler's freedom. `cores` is topology, not a pin |

---

## Hardware audit (read-only)

| | |
|---|---|
| CPU / RAM | Xeon E5-2697 v3, 14C/28T, 62 GiB, VT-d active |
| IOMMU | Already on (kernel default ≥ 6.8), IRQ remapping enabled, no ACS override |
| GPU | `05:00.0`, group **32 alone**; HDMI audio `05:00.1`, group **33 alone** |
| Link | PCIe 4.0 x16 (16 GT/s), stable |
| BARs | 256 MB + 2 MB + 1 MB. Resizable BAR is off; prox-1 proves ROCm works at this size |
| Reset | `reset_method: bus` only — see above |
| NVMe | 477 GB ext4 `/mnt/nvme`, 469 GiB free, 1.8 GB/s write / 2.8 GB/s read (DRAM-less) |
| Network | `vmbr0` 192.168.3.56/24, gw/DNS .1; MAC `BC:24:11:53:54:52` for the reservation |
| BMC | none (`/dev/ipmi*` absent, no IPMI in DMI) |

---

## Runbook

All commands from the repo root unless stated. The `ssh` path assumes your key
or agent; the path in the original request (`.ssh/id_ed25519`) does not exist in
this checkout.

```sh
scp -r proxmox/strata-vm root@192.168.3.56:/root/
ssh root@192.168.3.56
```

### Stage 1 — host prep (one reboot)

```sh
DRY_RUN=1 bash /root/strata-vm/00-host-prep.sh   # review
bash /root/strata-vm/00-host-prep.sh
reboot
```

Adds to GRUB: `iommu=pt pcie_aspm=off`. Writes
`/etc/modules-load.d/vfio.conf` (`vfio`, `vfio_iommu_type1`, `vfio_pci`) and
installs the hookscript to `/mnt/nvme/snippets/`. No GPU runtime-PM change on
the host: the hookscript resumes it before unbinding. Backs up GRUB and
`modprobe.d` to `/root/proxmox-prep-*`.

After reboot:

```sh
cat /proc/cmdline
lsmod | grep vfio
lspci -nnk -s 05:00.0        # expect: Kernel driver in use: amdgpu
```

### Stage 2 — create the VM

```sh
bash /root/strata-vm/10-create-vm.sh
qm start 200
```

Open VM 200 → Console (noVNC). The GPU is **not** attached yet, so the install
cannot be derailed by the reset bug.

### Stage 3 — install Ubuntu 26.04 Server (manual)

| Prompt | Answer |
|---|---|
| Type | Ubuntu Server (not minimized) |
| Network | **DHCP**; reserve MAC `BC:24:11:53:54:52` on the router |
| Proxy / mirror | none / default |
| Storage | entire disk, **no LVM**, ext4 |
| Hostname | `strata` |
| User | your choice (`strata` is assumed by the guest script) |
| OpenSSH | **yes**, import/paste your public key |
| Ubuntu Pro / snaps | skip / none |

Shut the VM down cleanly when the installer finishes.

### Stage 4 — attach the GPU + hookscript

```sh
bash /root/strata-vm/20-attach-gpu.sh
qm start 200
```

This removes the installer ISO, boots from `scsi0`, and sets
`hostpci0: 0000:05:00.0,pcie=1` (GPU, single function for atomics),
`hostpci1: 0000:05:00.1,pcie=1` (audio, so vfio can reset the whole device) and
`hookscript: nvme:snippets/strata-gpu-handoff.sh`.

### Stage 5 — guest setup

From the Proxmox host, with the VM IP from your DHCP reservation:

```sh
ssh <user>@<vm-ip> 'sudo bash -s' < /root/strata-vm/30-guest-setup.sh
```

Installs base packages + guest agent, sets `amdgpu.runpm=0` (no BACO runtime
suspend in the guest) and `vm.max_map_count=1048576`, clones Strata to
`/opt/Strata`, writes the worker clamp and `strata.service`, then starts the
interactive setup in tmux. **ROCm is optional** (`INSTALL_ROCM=1`); Strata's
Linux package carries its own HIP runtime and prox-1 runs on the kernel driver
alone. Never install `amdgpu-dkms` on this kernel.

```sh
ssh <user>@<vm-ip>
sudo tmux attach -t strata-setup
```

Setup choices (same as prox-1): HIP backend, **IQ3_S**, context 128K, KV int8,
MTP resident, let it pick low-RAM mode + CPU vision encoder on 20 GB. When it
finishes it starts its own engine — **stop it (Ctrl+C) before enabling the
service**, or two engines share 52 GiB and get OOM-killed.

```sh
sudo /usr/local/sbin/strata-fix-workers     # enforce --pool-workers 13
sudo systemctl enable --now strata
systemctl status strata --no-pager
```

### Stage 6 — verify

```sh
bash /root/strata-vm/40-verify.sh          # host + guest, read-only
CYCLE=1 bash /root/strata-vm/40-verify.sh  # the real test: shutdown -> start
```

The cycle test is the acceptance test. If the card does not come back on
`amdgpu`, the host needs a reboot — that is the reset bug, not a config error.

Once it passes, make the VM start with the host:

```sh
qm set 200 --onboot 1
```

---

## BIOS / UEFI checklist (JGINYUE X99-TI D4 PLUS)

**Nothing here is currently blocking**: VT-d is already active (DMAR present),
the IOMMU groups are clean, and the host boots UEFI. Check only if you are in
there anyway.

| Setting | Value | Why |
|---|---|---|
| VT-d / Intel Virtualization Technology for Directed I/O | **Enabled** | Already active; do not switch to Auto |
| Above 4G Decoding | On, if present | Standard for large BARs; not blocking at 256 MB |
| CSM / Legacy boot | Disabled (UEFI only) | The host is UEFI + GRUB; OVMF guests expect UEFI |
| Secure Boot | Off | Avoids signing/OVMF friction; not needed here |
| Primary display | PEG / PCIe | Only option, no iGPU |
| Resizable BAR | optional | X99 usually lacks it; do not chase it |
| IOMMU / ACS | leave default | Never enable ACS override for this card |
| x2apic | leave the BIOS opt-out as is | IRQ remapping runs in xapic mode and works |
| ASPM | leave Auto | The host cmdline disables ASPM globally |

---

## Boot configuration

### Host (`/etc/default/grub`, applied by `00-host-prep.sh`)

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet iommu=pt pcie_aspm=off"
```

| Flag | Why |
|---|---|
| `iommu=pt` | Passthrough mode; recommended by the PVE wiki and ROCm. Devices not assigned to a VM bypass translation |
| `pcie_aspm=off` | Keeps PCIe links out of low-power states; removes a latency/flakiness tail on X99 with a passed-through GPU |
| `amd_iommu=on` | **Not used.** Not a valid option; AMD-Vi is on by default. The kernel logs `Unknown option - 'on'` (AMD's own 2026 article still copies it) |
| `intel_iommu=on` | **Not used.** Default on since kernel 6.8; this is 7.0 |
| `initcall_blacklist=sysfb_init` | **Not used.** Only needed when `vfio-pci` binds the primary GPU at boot |
| `pcie_acs_override` | **Not used.** The GPU is alone in group 32 |

Do not pin a kernel yet. If a future kernel regresses VFIO, pin the working one
(`proxmox-boot-tool kernel pin` on systemd-boot; `GRUB_DEFAULT` here).

### Guest (Ubuntu)

Keep it stock. **IOMMU flags are host-side**; the guest has no IOMMU unless you
add a vIOMMU, and `pcie_aspm`/C-state knobs describe real PCIe links and real
idle states that the guest does not own. Do not add `amd_iommu=on`.

Optional, small latency win only:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet nowatchdog nmi_watchdog=0"
```

Tuning that *does* matter for Strata:

| Knob | Value | Where |
|---|---|---|
| `vm.max_map_count` | `1048576` | `/etc/sysctl.d/90-strata.conf` |
| `LimitMEMLOCK` | `infinity` | `strata.service` (ROCm pinned host allocations) |
| `--pool-workers` | `13` | enforced by `/usr/local/sbin/strata-fix-workers` |
| `STRATA_AUX_CPUS` | `auto` | unit environment (helper threads use the free vCPUs) |
| PLE table / model | on `/mnt/nvme` via the VM disk | keep the engine warm; first load is I/O bound |
| Host CPU governor | `performance` (optional) | steady worker clocks on this Xeon: `cpupower frequency-set -g performance` |

Stop the VM with `qm shutdown 200`, not `qm stop`, whenever you can. A clean ACPI
shutdown lets the guest driver quiesce the GPU before vfio-pci releases it.

## Hardening (optional, later)

- `strata.service` runs as root because setup writes root-owned model files, same
  as prox-1. To drop privileges: `chown -R strata:strata /opt/Strata`, add
  `User=strata` / `Group=strata` to the unit, and keep the user in `render,video`.
- Strata's API accepts any API key, so it is effectively unauthenticated. Keep it
  on the LAN, or bind it to `127.0.0.1` and put a reverse proxy with auth in front.

---

## Sizing

| Resource | Value | Reason |
|---|---|---|
| RAM | 52 GiB, balloon off | **VFIO pins the whole guest RAM** (`VmLck` = 52 GiB, `VmSwap` = 0), so swap cannot help. 58 GiB caused real memory pressure (7 journald events) and stalled the host; 56 GiB had **no** memory-pressure events and froze on the GPU reset bug instead. 52 GiB leaves ~8 GiB and is the proven-stable baseline. 20 GB VRAM + 52 GiB = 72 GB, above the 64 GB requirement for IQ3_S |
| vCPU | 24 (1 socket, 24 cores) | PVE cannot expose SMT; leaves 4 host threads for Proxmox/QEMU I/O; 13 workers is enforced explicitly |
| Disk | 380 GB qcow2 on `nvme` | model ~84 GB + ~50 GB low-RAM copy + cache ≈ 150 GB; leaves ~88 GiB on the NVMe |
| Swap in guest | 2–4 GiB | only a safety net; do not rely on it |
| Backups | not on this NVMe | 380 GB does not fit next to itself; send backups to another host/NAS |

---

## Gotchas

| Symptom | Cause / fix |
|---|---|
| `qm start` fails: *device is not responding; recovering it may need a host reboot* | Card left wedged by the previous run. Reboot the host. Check `/var/log/strata-gpu-handoff.log` |
| Second start shows nothing / `amdgpu` fails to init | The Navi 31 reset bug. The hookscript recovers most cases; a host reboot is the fallback |
| Guest: `PCIE atomic ops is not supported` | You passed `05:00` (all functions). Pass `05:00.0` only |
| ROCm: *operation cannot be performed in the present state* | Same atomics cause as above; check the guest root port for `AtomicOpsCap: 32bit+ 64bit+` |
| `amdgpu-dkms` fails to build | Expected on kernel 7.0 (`zone_device_page_init`). Use the inbox driver; never install the DKMS package |
| Strata runs ~27 workers and is slow | `sudo /usr/local/sbin/strata-fix-workers && sudo systemctl restart strata`; verify with `journalctl -u strata` |
| Host console goes dark when the VM starts | Single GPU, no iGPU/BMC. SSH + Proxmox UI only |
| Two engines, OOM kill | Setup's engine is still running in tmux. Stop it before `systemctl start strata` |
| Host stalls after start, with `journald: Under memory pressure` | The VM RAM exceeds what VFIO can pin. At 58 GiB the host had 7 pressure events; keep **52 GiB**. Host swap cannot help: pinned guest RAM is unevictable |
| Host stalls after start, **no** memory-pressure messages, last kernel line is the GPU ROM read | vfio-pci could not reset the GPU because the audio group was not owned. Pass `hostpci1: 05:00.1`; do not just add RAM |
| `kvm: vfio: Cannot reset device ... depends on group 33 which is not owned` | The HDMI audio function is still on the host. Pass it as `hostpci1: 05:00.1`. Without it the GPU is never reset cleanly before the guest initializes it |
| Guest hangs the host after boot | Guest amdgpu BACO runtime PM on a passed Navi 31. `30-guest-setup.sh` adds `amdgpu.runpm=0` to the guest's GRUB. If it persists, add it to the host too |
| AER errors from `05:00.1` | The HDMI audio function stays on the host by design. If it logs errors, `echo 0000:05:00.1 > /sys/bus/pci/drivers/snd_hda_intel/unbind` (or blacklist `snd_hda_intel` if the host needs no audio) |
| Model load is slower than prox-1 | This NVMe is DRAM-less: 1.8 GB/s write. Sequential, so acceptable, but first load is slower |

---

## Rollback

```sh
# keep the VM, drop the GPU
qm stop 200
qm set 200 --delete hostpci0 --delete hookscript
qm start 200

# remove the VM and its disk
qm destroy 200

# host-side (then reboot)
cp /root/proxmox-prep-*/grub /etc/default/grub
rm -f /etc/modules-load.d/vfio.conf /mnt/nvme/snippets/strata-gpu-handoff.sh
update-grub && update-initramfs -u -k all
```

Nothing else on the host is modified.

---

## Sources

- Proxmox wiki, PCI(e) Passthrough — IOMMU on by default, `iommu=pt`, q35/OVMF
- Proxmox forum, *[SOLVED] AMD RX 7800/9070 XT vendor-reset?* (Jan 2026) — AMD's
  passthrough statement for 7900 XTX
- Proxmox forum, *AMD GPU passthrough & reset hookscript that works through
  guest shutdowns* (Dec 2025) and *[SOLVED] PVE9 + AMD 9070 XT now work* — the
  amdgpu ⇄ vfio-pci handoff pattern
- `gnif/vendor-reset` issue #97 — 7000 series unsupported (open)
- QEMU `vfio_pci_enable_rp_atomics()` and the 2026 devel thread *Don't disable
  PCIe atomic routing for multifunction devices* — single-function requirement
- ROCm docs, *PCIe atomics*; ROCm issue #6520 — atomics and hostcall failures
- Ubuntu blog, *AI with AMD ROCm on Ubuntu* (Jun 2026) — `apt install rocm`,
  ROCm 7.1 in 26.04, no DKMS
- Strata `docs/AMD_HIP.md`, `docs/CAPABILITIES.md`, issue #3417 — gfx1100
  support, packaged HIP runtime, worker scaling
- Local: prox-1 `proxmox/gpu-passthrough/README.md` — same GPU/CPU, proven LXC
  baseline and the 13-worker result
