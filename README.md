# Homelab

| Path | What |
|---|---|
| `docs/` | documentation: plain-language guides, the build path, reference and the undervolt folder |
| `proxmox/prox-2/` | prox-2: fresh PVE 9.2, no-subscription repos, 36 G root + 175 G thin pool, 468 G NVMe storage |
| `proxmox/gpu-passthrough/` | prox-1: Strata LLM in an LXC with an RX 7900 XT |
| `proxmox/strata-vm/` | prox-2: VM + VFIO attempt, reverted — kept as the reset-bug / pinned-RAM record |
| `proxmox/strata-lxc/` | prox-2: Strata in LXC 121, Debian 13, RX 7900 XT via `/dev/kfd`, rootfs on NVMe |
