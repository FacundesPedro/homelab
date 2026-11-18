# Strata on prox-1 (RX 7900 XT, 20 GB) — LXC, no passthrough

Local LLM inference with [Strata](https://github.com/Niko1221/Strata) in a Proxmox
LXC. The host keeps the `amdgpu` driver; the container borrows `/dev/kfd` and
`/dev/dri` device nodes. No VFIO, no kernel changes, no reboot.

## Host

| | |
|---|---|
| Proxmox | PVE 9.2.26, kernel 7.0.14-28-pve |
| CPU | Xeon E5-2697 v3, 14 cores / 28 threads, AVX2 |
| RAM | 64 GiB |
| GPU | RX 7900 XT, 20 GB, `05:00.0` (`1002:744c`, gfx1100), amdgpu loaded |
| Disk | 480 GB SATA SSD, `local-lvm` 399 GB |

## Why not passthrough

The 7900 XT/XTX (RDNA3, Navi 31) has the AMD reset bug; AMD officially does not
support PCI passthrough for it and `vendor-reset` does not cover Navi 31. LXC
device sharing avoids the issue entirely, costs nothing in performance for
compute, and leaves the GPU usable by the host.

## Strata on this GPU

Strata's HIP backend supports gfx1100 (maintainer-tested) and runs on the kernel
driver alone — no system ROCm, no CUDA. The **IQ3_S** pack is the right tier:
20 GB VRAM + 56 GiB RAM = 76 GB, above the documented 64 GB requirement.

| Item | Value |
|---|---|
| Model | Qwen3.8-Flash-Next GSQ-RCO IQ3_S |
| Disk needed | ~150 GB (model 84 GB + 50 GB low-RAM expert copy + cache) |
| Expected | roughly 50–60 tok/s warm decode (single 7900 XTX bench: 56–64) |

**SATA SSD caveat:** first load and cold prompts are slower; warm chats are
served from VRAM/RAM. Keep the engine running and keep the PLE table in RAM
(`STRATA_PLE_AUTO_RAM=1`, default when it fits).

## Thread pinning

Strata pins one CPU worker per **physical core** and skips the host core, so on
this Xeon it uses 13 workers on cores 0–13 and leaves SMT siblings free. Do not
raise `--pool-workers`: Strata measured 27.9 vs 38.1 tok/s (37% slower) when
workers exceed physical cores (issue #3417). The systemd unit sets
`STRATA_AUX_CPUS=auto` so helper threads use the otherwise idle siblings.
`--pool-cores` exists for explicit layouts and is not needed on a single socket.

`cores` in Proxmox is not a pin; `lxc.cgroup2.cpuset.cpus` would be. This setup
leaves scheduling to the kernel and pinning to Strata's own pool planner.

## Container

| | |
|---|---|
| ID / host | `120` / `strata` |
| Template | Debian 13, unprivileged |
| RAM / swap | 56 GiB / 4 GiB |
| Cores | 28 |
| Disk | 210 GiB on `local-lvm` |
| Devices | `/dev/kfd`, `/dev/dri/renderD128`, `/dev/dri/card1` |
| Service | `strata.service`, port 8080 |

## Scripts

Run on `prox-1` as root:

| Script | Purpose |
|---|---|
| `00-check-host.sh` | Read-only audit: GPU driver, device nodes/GIDs, memory, storage |
| `10-create-strata-lxc.sh` | Creates CT 120, device nodes, deps, clones Strata, starts setup in tmux |
| `20-verify-strata.sh` | Checks device access, service state, API health, worker placement |
| `30-strata-control.sh` | `start` / `stop` / `restart` / `status` / `logs` |

```sh
scp -r proxmox/gpu-passthrough root@prox-1:/root/
ssh root@prox-1 'bash /root/gpu-passthrough/00-check-host.sh'
ssh root@prox-1 'bash /root/gpu-passthrough/10-create-strata-lxc.sh'

pct enter 120                       # setup runs in tmux
tmux attach -t strata-setup
# choose HIP backend, IQ3_S, 128K context, int8 KV, projection off
# (setup picks low-RAM mode + CPU vision encoder automatically on 20 GB)
# Setup starts its own engine at the end. Stop it (Ctrl+C in tmux) BEFORE
# enabling the service, or two engines share 56 GiB and get OOM-killed:

pct exec 120 -- systemctl enable --now strata
```

Overrides: `MEMORY_MB=49152 ROOTFS_GB=200 CTID=121 bash 10-create-strata-lxc.sh`.

## Access

| | |
|---|---|
| Web UI | `http://<ct-ip>:8080` |
| OpenAI API | `http://<ct-ip>:8080/v1` (any API key; any model name) |
| Anthropic API | `http://<ct-ip>:8080/v1/messages` |
| Service | `systemctl status strata` inside the CT |

Stopping the container frees the 56 GiB RAM and the GPU:

```sh
bash 30-strata-control.sh stop
bash 30-strata-control.sh start
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `verify: unspecified launch failure`, then "no ROCm-capable device" | GPU ring wedged; VRAM stays allocated after exit. Reboot prox-1 (cleanest). |
| GPU disappears from `lspci` after an AER fatal | PCIe link is down; a warm reboot does not retrain it. Cold power cycle (unplug PSU 30 s). |
| Service OOM-killed while two engines run | Setup's engine is still open in tmux; stop it before `systemctl start strata`. |
| `nvtop` says "No GPU to monitor" | Container detection limitation; use Strata's Monitor page or `/sys/class/drm/card1/device/gpu_busy_percent`. |

## Rollback

```sh
pct stop 120 && pct destroy 120
```

Nothing outside `/etc/pve/lxc/120.conf` and the container itself is touched.

## Sources

- Strata `docs/AMD_HIP.md`, `docs/DETAILS.md`, issues #106, #3262, #3417
- Proxmox admin guide: LXC device passthrough (`dev[n]`)
- Proxmox forum: AMD RDNA3 reset bug, vendor-reset support matrix
