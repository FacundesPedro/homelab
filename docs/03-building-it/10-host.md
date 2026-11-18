# The host (Proxmox)

The reference host build is in `../../proxmox/prox-2/README.md`. This page is
the generic checklist with the reference values for comparison.

## Install and storage

- Proxmox VE 9.x from the ISO; Debian 13.
- The `pve-no-subscription` repo; remove the enterprise and Ceph repos.
- The OS disk holds the PVE root and thin pool. Keep the root small so a stray
  backup cannot fill it.
- Add the fast disk as a **directory storage**. The reference mounts a 477 GB
  NVMe at `/mnt/nvme` (`noatime`) and registers it with
  `backup,rootdir,snippets,vztmpl,iso,images`.
- Backups go to the fast storage or to a separate disk, never to a full root.
- Configure the bridge. The reference is `vmbr0` at `192.168.3.56/24`,
  gateway/DNS `192.168.3.1`.

| Storage | Type | Reference size | Content |
|---|---|---|---|
| `local` | dir (`/var/lib/vz`) | 36 GB | `iso`, `vztmpl` |
| `local-lvm` | lvmthin | 175 GB | `images`, `rootdir` |
| `<STORAGE>` | dir (`<STORAGE_PATH>`) | 468 GB | `backup`, `rootdir`, `snippets`, `vztmpl`, `iso`, `images` |

## BIOS

Exact menu names vary by vendor. Look for these:

| Setting | Value | Why |
|---|---|---|
| Above 4G Decoding | Enabled | prerequisite for a large BAR |
| Re-Size BAR Support | Enabled **if present** | lets the CPU see more VRAM; not required |
| Restore on AC Power Loss | **Power On** | a smart plug can cold-cycle the host remotely |
| CSM | Disabled | UEFI boot |
| Secure Boot | Off | not needed |
| VT-d / IOMMU | leave enabled | unused by the LXC; useful for a future VM |
| PCIe ASPM | Off/Auto | the kernel flag already disables it |
| Wake-on-LAN | Enabled | optional; same remote-power goal |
| SR-IOV | Off | not used |

Do not chase ReBAR on old boards. Many X99 boards do not expose it; the
reference runs with it **disabled** and 256 MiB of CPU-accessible VRAM. Check
after any change:

```sh
lact cli info | grep -iE 'resizable|accessible|PCIe Link'
lspci -vv -s <GPU_PCI> | grep -A1 'Region 0'
```

## Kernel flags

Edit `/etc/default/grub`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet iommu=pt pcie_aspm=off amdgpu.ppfeaturemask=0xfff7ffff amdgpu.runpm=0"
```

Then:

```sh
update-grub
reboot
```

| Flag | Why |
|---|---|
| `iommu=pt` | passthrough mode; harmless for the LXC, useful for a future VM |
| `pcie_aspm=off` | avoids PCIe link power-state latency/flakiness on older boards |
| `amdgpu.ppfeaturemask=0xfff7ffff` | enables the **overdrive** bit (`0x4000`) so LACT can set voltage/clocks/fan. Proxmox's stock value is often `0xfff7bfff` (OD off) |
| `amdgpu.runpm=0` | keeps the GPU awake; avoids BACO runtime-PM transitions and keeps the sensors readable |

`amd_iommu=on` and `intel_iommu=on` are **not** needed on kernel 7.0: IOMMU is
on by default for Intel since 6.8, and `amd_iommu=on` is not a valid option at
all.

## Checks

```sh
pveversion | head -1
pvesm status
df -h / <STORAGE_PATH>
lspci -nnk -s <GPU_PCI>          # Kernel driver in use: amdgpu
lact cli info | grep -iE 'resizable|PCIe Link'
free -m
```

The GPU must show `amdgpu`, and the host must have `/dev/kfd` and
`/dev/dri/renderD128`. Do **not** blacklist `amdgpu` and do not pre-bind
`vfio-pci`: the container shares the host driver.

## The smart plug option

If the board has no BMC, a Wi-Fi smart plug plus **Restore on AC Power Loss =
Power On** gives a remote cold power cycle after a GPU wedge. This is the one
hardware addition that removes the "walk to the server" recovery. Match the
plug to the PSU's inrush current (a 10–16 A rated plug is fine).
