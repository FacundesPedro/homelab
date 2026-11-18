# prox-2 — Proxmox VE 9.2

| | |
|---|---|
| Host | `prox-2.local` / `192.168.3.56` |
| PVE | 9.2.28, kernel 7.0.14-29-pve, Debian 13 (trixie) |
| CPU / RAM | 28 threads / 62 GiB |
| OS disk | 224 GB SATA, LVM (`pve`) |
| Data disk | 477 GB NVMe, ext4 → `nvme` |
| Subscription | none → `pve-no-subscription` repos |
| Cluster | standalone, no guests yet |

## Repositories

deb822 files in `/etc/apt/sources.list.d/`:

| File | Suites / component |
|---|---|
| `debian.sources` | `trixie`, `trixie-updates`, `trixie-security` |
| `pve-no-subscription.sources` | `trixie pve-no-subscription` |

- `pve-enterprise.sources` and `ceph.sources` removed (no Ceph). Backup: `/root/apt-backup-*`.
- The no-subscription repo uses **http**, not https: `download.proxmox.com` serves a
  certificate that does not cover its own hostname (confirmed from two networks).
  apt still verifies every package against `proxmox-archive-keyring.gpg`.
- No `/etc/apt/sources.list` on PVE 9; everything lives in `.sources` files.

```sh
apt update && apt policy proxmox-ve
```

## Storage

| Name | Type | Size | Content |
|---|---|---|---|
| `local` | dir, `/var/lib/vz` on root | 36 G | `iso`, `vztmpl` |
| `local-lvm` | lvmthin `pve/data` | 175 G | `images`, `rootdir` |
| `nvme` | dir, `/mnt/nvme` | 468 G | `backup`, `iso`, `vztmpl`, `images`, `rootdir`, `snippets` |

- **Backups go to `nvme`.** `local` is deliberately small and no longer accepts
  `backup`/`import`, so a stray backup cannot fill root and take the node down.
- Root is 36 G: ~6 G Proxmox + ~30 G for ISOs. It was shrunk from 65 G; the
  freed space went to the thin pool (130 → 175 G).
- `nvme` is a plain ext4 filesystem with `noatime`, mounted by UUID in `/etc/fstab`
  (`is_mountpoint` set, so PVE refuses to write if it is not mounted).
- Source disk was a CachyOS desktop, wiped on purpose. Manifest of what was
  there: `/root/nvme-old-os-manifest.txt`.

## Changes vs. fresh install

| Change | How |
|---|---|
| Enterprise repos → no-subscription | `.sources` rewritten, Ceph repo disabled |
| 36 G root, 175 G thin pool | one-shot initramfs hook, offline resize |
| NVMe as `nvme` storage | wipe, GPT, ext4, fstab, `pvesm add dir` |
| Subscription popup removed | `proxmoxlib.js` patched, backup alongside |
| HA services | `pve-ha-lrm` / `pve-ha-crm` disabled (standalone) |
| Kernel | upgraded from 7.0.2 to 7.0.14 |

## Offline root shrink (reproducible)

`/etc/initramfs-tools/scripts/local-premount/pve-shrink` runs before root is
mounted and no-ops once root ≤ 40 G, so it cannot run twice. It was removed from
the initramfs after verification. The build hook copies `resize2fs` (not shipped
by default) into the initramfs.
The commands it runs:

```sh
e2fsck -f -y /dev/mapper/pve-root
resize2fs /dev/mapper/pve-root 36G
lvm lvreduce -L 36G -y /dev/mapper/pve-root
lvm lvextend -l +100%FREE /dev/mapper/pve-data
```

ext4 cannot shrink while mounted, and this board has no IPMI/BMC — the hook
exists so the operation needs one reboot, not a physical console.

## Checks

```sh
pveversion -v | head -1
pvesm status
df -h / /mnt/nvme
systemctl --failed
apt-get -s full-upgrade | grep -c ^Inst   # expect 0
```

## Gotchas

| Symptom | Cause / fix |
|---|---|
| Subscription popup returns | a `proxmox-widget-toolkit` update overwrites `proxmoxlib.js`; re-apply the `void({ //Ext.Msg.show` patch |
| `apt` fails with `401 Unauthorized` | an enterprise `.sources` file is back; remove it |
| `apt` fails on `download.proxmox.com` TLS | do not switch that repo to https; the CDN cert does not cover the hostname |
| `local` fills up | backups are pointed at `local`; move them to `nvme` |
| Node won't boot after disk work | no IPMI on this X99 board; a monitor/keyboard or live USB is the only console |
