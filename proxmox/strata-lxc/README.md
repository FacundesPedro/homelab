# Strata on prox-2 — LXC 121, RX 7900 XT, NVMe

> **Scope.** This is the reference deployment's runbook: every value below is
> specific to prox-2. For reproduction on another machine, start with
> [`../../docs/`](../../docs/README.md); the scripts accept `CTID`, `STORAGE`,
> `GPU_PCI` and friends as environment variables.

**Status:** running. CT 121 on NVMe, Strata Qwen3.8-Flash-Next IQ3_S at **256K context**;
`strata.service` enabled. The GPU is undervolted through LACT: **-100 mV,
2760 MHz, 231 W cap**, PMFW fan. 5-minute burn: **86 °C junction, 145 W,
93 launches**. Inference: ~34 tok/s cold, warm 45–54 tok/s; idle 12 W / 38 °C.

The stock card pinned the junction at 110 °C within seconds — that is what
produced the `sdma1 timeout` / `device lost from bus` crash. The fix is the LACT
profile below (the card was never locked; overdrive was disabled). A repaste is
still worth doing for the 45 °C edge-junction delta, but the card is stable now.

This replaces the VM + VFIO attempt in `../strata-vm/`. The VM worked, but only
after fighting the Navi 31 reset bug and the VFIO RAM pinning; the LXC avoids
both by keeping the GPU on the host driver.

| | |
|---|---|
| Host | prox-2, `192.168.3.56`, PVE 9.2.28, kernel `7.0.14-29-pve` |
| CT | `121` / `strata-2`, Debian 13.6, unprivileged |
| CPU / RAM | 28 cores (cgroup limit), 56 GiB RAM + 4 GiB swap |
| Disk | 380 GB raw rootfs on **`nvme`** (`/mnt/nvme/images/121/`) |
| GPU | RX 7900 XT `05:00.0`, host `amdgpu`, shared via `/dev/kfd` + `/dev/dri` |
| Devices | `dev0 /dev/kfd gid=992`, `dev1 renderD128 gid=992` (cardN is not passed — it renumbers) |
| Extras | `lxc.prlimit.memlock: unlimited`, `features fuse=1,nesting=1` |

## Why LXC here

| | VM + VFIO (reverted) | This LXC |
|---|---|---|
| GPU | `vfio-pci`, bus reset, audio-group reset dependency | host `amdgpu`; no reset |
| RAM | 52 GiB **pinned** (`VmLck`), 58 GiB stalled the host | 56 GiB **cgroup**, not pinned |
| CPU view | 24 cores, no SMT → manual `--pool-workers 13` | **14C/28T** → Strata picks 13 |
| Storage | qcow2 + virtio | raw rootfs directly on NVMe |
| Recovery | stop/start can wedge the card | restart the container |

The VM is kept in `../strata-vm/` only as the record of the reset-bug and
memory-pinning findings.

## Tested before building

A throwaway CT 199 on `nvme` validated the whole path:

| Test | Result |
|---|---|
| Rootfs on `nvme` | `nvme:199/vm-199-disk-0.raw`, raw sparse image |
| NVMe throughput inside the CT | **2.3 GB/s** (512 MiB, `oflag=direct`) |
| Device nodes | `/dev/kfd`, `/dev/dri/renderD128` visible |
| Container GIDs | **render=992**, video=44 (host render is 993 — the `gid=` must be the container value) |
| CPU topology | 28 CPUs, 2 threads/core, 14 cores, 1 socket |
| memlock | `Max locked memory unlimited` with `lxc.prlimit.memlock: unlimited` |
| Network | DHCP on `vmbr0`, ping OK |
| Bundled ROCm in the CT | `rocminfo` → `gfx1100`, RX 7900 XT, BDF `0000:05:00.0` |
| Stock 30 s burn | **junction 110 °C** in ~4 s — the crash cause |
| Final LACT profile | 5-min burn **86 °C**, 145 W, 93 launches (see below) |

A first attempt failed because `/sys/class/drm/cardN/device` resolves to
`/sys/devices/...`, not `/sys/bus/pci/devices/...`. The scripts now resolve both
sides with `readlink -f`.

## GPU tuning (LACT)

The Creator blower cannot dissipate the stock ~250 W: the junction hits the
110 °C limit in seconds. The firmware also ignored `amd-smi` and hwmon power/fan
writes — but only because **amdgpu overdrive was disabled**:

- Host `ppfeaturemask` was `0xfff7bfff`; the OD bit `0x4000` was off.
- GRUB now has `amdgpu.ppfeaturemask=0xfff7ffff amdgpu.runpm=0`.
- `pp_od_clk_voltage` exposes `VDDGFX_OFFSET: -450..0 mV` and MCLK up to 1500 MHz.

LACT v0.10.1 **headless Debian 13** package:

```sh
wget https://github.com/ilya-zlobintsev/LACT/releases/download/v0.10.1/lact-headless-0.10.1-0.amd64.debian-13.deb
apt install ./lact-headless-0.10.1-0.amd64.debian-13.deb
systemctl enable --now lactd
lact cli list-gpus      # 1002:744C-1849:5332-0000:05:00.0
```

Final `/etc/lact/config.yaml`:

```yaml
daemon:
  log_level: info
gpus:
  "1002:744C-1849:5332-0000:05:00.0":
    fan_control_enabled: false
    pmfw_options:
      acoustic_limit: 4950
      acoustic_target: 2500
      minimum_pwm: 30
      target_temperature: 80
      zero_rpm: false
    power_cap: 231
    max_core_clock: 2760
    voltage_offset: -100
    performance_level: auto
```

Tuning, 30 s HIP burn unless noted (`launches` = throughput, 98 = stock):

| Setting | Power | Junction | Launches |
|---|---:|---:|---:|
| stock | 240–250 W | 110 °C | 98 |
| + PMFW fan | ~245 W | 103 °C | 98 |
| + 231 W cap | 230 W | 101 °C | 98 |
| -25 mV | 230 W | 103 °C | 99 |
| -50 mV, 2400 MHz | 98 W | 62 °C | 81 |
| -50 mV, 2600 MHz | 127 W | 70 °C | 88 |
| -50 mV, 2860 MHz | 175 W | 87 °C | 96 |
| -75 mV, 2860 MHz | 165 W | 85 °C | 96 |
| -100 mV, 2860 MHz | 155 W | 83 °C (93 °C, 5 min) | 96 |
| **-100 mV, 2760 MHz** | **145 W** | **86 °C, 5 min** | **93** |

The power cap is the card's minimum (231 W) and is not binding at 145 W. The
voltage-only steps did not lower the temperature while the power cap let the card
boost into the same budget; the **max clock** is the lever.

Inference at the final profile: `33.8 tok/s` cold, warm `45–54 tok/s` (the expert
cache fills during the first requests). Peak during a request: 64 °C, 115 W.
`max_tokens` below ~64 is consumed by the thinking budget and returns
`content: null`; use `reasoning_budget_tokens` or a larger `max_tokens`.

**Memory overclock: tested and rejected.** LACT applied `max_memory_clock: 1300`
(`OD_MCLK: 1300`), but during inference the memory DPM stayed at **772 MHz** —
the decode is not GPU-memory-bound. The tok/s spread was cache warm-up, not the
clock. Reverted to 1250; GDDR6 has no ECC, so there is no reason to take the risk.

The fan is firmware-controlled on RDNA3; `zero_rpm: false` + `minimum_pwm: 30`
gives ~1,900 RPM idle and ~3,000 RPM at 86 °C. The remaining physical fix for the
45 °C edge-junction delta is a repaste (PTM7950) and case airflow.

## Runbook

Run on prox-2 as root:

```sh
bash /root/strata-lxc/00-check-host.sh      # read-only audit
bash /root/strata-lxc/10-create-strata-lxc.sh
```

`10-create` is idempotent about the template and refuses to touch an existing
CT. It creates the CT, starts it once to read the **container-side** render/video
GIDs, stops it, writes the three `dev` entries, starts it again, then installs
the packages, clones Strata, writes `strata.service` and starts `setup.sh` in
tmux.

The setup choices used (same as prox-1):

```
Model:   Qwen3.8-Flash-Next (GSQ-RCO, ISTA-DASLab)   [1]
Size:    IQ3_S (84 GB download, ~50 GB RAM)          [4]
Context: 128K                                         [4]
KV:      8-bit                                        [1]
Images:  on, encoder on CPU (auto)
Low-RAM: GPU holds ~25% of experts, ~38 GB in RAM (auto)
Projection: off                                       [n]
```

Then:

```sh
pct enter 121
tmux attach -t strata-setup
```

When setup finishes it starts its own engine. **Stop it (Ctrl+C) before
enabling the service**, or two engines share 56 GiB and get OOM-killed:

```sh
systemctl enable --now strata
```

Verify:

```sh
bash /root/strata-lxc/20-verify-strata.sh
```

Control:

```sh
bash /root/strata-lxc/30-strata-control.sh start|stop|restart|status|logs
```

## Strata settings

| Setting | Value | Why |
|---|---|---|
| Workers | automatic, 13 | The CT sees 14 physical cores; Strata uses one per core and skips the host core. Do **not** raise it (issue #3417: 27.9 vs 38.1 tok/s) |
| `STRATA_AUX_CPUS` | `auto` | Helper threads use the SMT siblings the workers do not pin |
| `LimitMEMLOCK` | `infinity` | ROCm pinned host allocations for the expert arena |
| Context / KV | 256K / int8 (q8) | 20 GB VRAM: 19.8/20.4 GiB; real RAM 43.6 GiB (76.1%; cgroup also holds ~13.6 GiB page cache); 8K 552 tok/s, 32K 572 tok/s |
| Low-RAM mode | on | 56 GiB RAM + 20 GB VRAM for a ~84 GB pack |
| Pack location | `/opt/Strata` on the NVMe rootfs | first load is I/O bound; keep it warm |
| GPU profile | LACT: -100 mV, 2760 MHz, 231 W, PMFW fan | 86 °C under a 5-min burn; 93 launches (95% of stock) |

## Access

| | |
|---|---|
| Web UI | `http://192.168.3.66:8080` |
| OpenAI API | `http://192.168.3.66:8080/v1` |
| Anthropic API | `http://192.168.3.66:8080/v1/messages` |
| Bind | `0.0.0.0:8080` (`--host 0.0.0.0` in `run-iq3_s.sh`) |
| Console | `pct enter 121` |
| Service | `systemctl status strata` inside the CT; enabled on boot |
| Measured | 33.8 tok/s cold, warm 45–54 (128K); 256K: 8K prompt 552 tok/s, decode 34.6 (84 tok), 32K 572 tok/s |
| Prompt reading | 8K 602 (128K) / 552 (256K), 16K 607, 32K at 256K **572** |
| 4K prompt note | 340 effective (10.98 s) because of a fixed ~5 s per-request/first-touch cost |

The CT 121 MAC is `BC:24:11:5E:73:CA` and it currently has `192.168.3.66` by
DHCP. Reserve that MAC on the router for a fixed address.

`api_key: false` — the API and web UI are reachable from the LAN with no auth.
Use it on the trusted LAN only. To secure it, add `--api-key <key>` to
`run-iq3_s.sh`, or bind `127.0.0.1` and put a reverse proxy/tunnel in front.

## Real memory

PVE's UI/`pvesh` `mem` is `memory.current - memory.stat.file` (the page cache is
excluded). `memory.current` alone is ~14 GiB higher and is not pressure.

| Metric | 8K test at 256K |
|---|---:|
| PVE `mem` (UI) | 43.4–43.6 GiB (76.1%) |
| `memory.current` | ~55.9 GiB |
| page cache (`file`) | 13.6 GiB |
| `anon` | 43.3 GiB |
| engine RSS | 43.2–43.3 GiB |
| swap | 740 MiB |
| VRAM | 19.8 GiB |
| GPU during prefill | 46–48 °C, ~100 W |
| host free / available | 3.0 / 15.7 GiB |

The 8K prompt read 7,376 tokens at **552 tok/s** and generated 84 at 34.6 tok/s
(`DONE`). The RAM stayed flat at 43.6 GiB; the context lives in VRAM.

Monitor on the host:

```sh
SAMPLES=30 INTERVAL=2 bash /root/strata-lxc/ram-monitor.sh
```

It prints the PVE/UI value, `anon`, page cache, `current - file`, engine RSS,
CT/host free, VRAM and the GPU junction/power.

Revert the context if needed:

```sh
pct exec 121 -- cp -a /opt/Strata/strata-iq3_s.json.200k /opt/Strata/strata-iq3_s.json  # 200K
pct exec 121 -- cp -a /opt/Strata/strata-iq3_s.json.bak  /opt/Strata/strata-iq3_s.json  # 128K
pct exec 121 -- systemctl restart strata
```

## Persistence

Everything below survives a reboot:

| What | Where |
|---|---|
| Strata starts on boot | `strata.service` enabled inside CT 121; CT `onboot: 1` |
| LAN bind | `--host 0.0.0.0` in `/opt/Strata/run-iq3_s.sh`; `STRATA_ALLOWED_HOSTS=192.168.3.66,strata-2` in the unit |
| Context | `--max-context 262144` in `/opt/Strata/strata-iq3_s.json`; backups `.bak` (128K) and `.200k` (200K); OpenCode `limit.context` 262144 |
| GPU profile | `lactd` enabled; `/etc/lact/config.yaml` (-100 mV, 2760 MHz, 231 W, PMFW fan) |
| Overdrive | GRUB `amdgpu.ppfeaturemask=0xfff7ffff amdgpu.runpm=0` |
| memlock | `lxc.prlimit.memlock: unlimited`; unit `LimitMEMLOCK=infinity` |

If `setup.sh` is ever re-run, it regenerates `run-iq3_s.sh` — re-add
`--host 0.0.0.0` afterwards.

## BIOS / firmware

Current (from `lact cli info`): **Resizable BAR disabled**, CPU-accessible VRAM
256 MiB, PCIe **Gen3 x16** (X99 is a PCIe 3.0 platform).

Enable, if the JGINYUE X99 BIOS exposes them:

| Setting | Value | Why |
|---|---|---|
| **Above 4G Decoding** | Enabled | prerequisite for a large BAR and the 16 GiB window |
| **Re-Size BAR Support / Resizable BAR** | Enabled | 256 MiB -> up to 16 GiB CPU-accessible VRAM; may help expert uploads/first load, not the in-GPU decode |
| **Restore on AC Power Loss** | Power On | a smart plug can then cold-cycle the host remotely after a GPU wedge |
| Wake-on-LAN | Enabled | optional, same goal |
| **CSM** | Disabled | UEFI boot (PVE is UEFI + GRUB) |
| Secure Boot | Off | not needed; avoids firmware friction |
| VT-d / IOMMU | leave enabled | not needed by the LXC, kept for a future VM |
| PCIe ASPM | Off/Auto | the host cmdline already has `pcie_aspm=off` |
| SR-IOV | Off | not used |

After the change, check:

```sh
lact cli info | grep -iE 'resizable|accessible|PCIe Link'
lspci -vv -s 05:00.0 | grep -A1 'Region 0'
```

`Resizable BAR: Enabled` and `CPU Accessible VRAM: 16384 MiB` (or 8192) means it
took. Re-run the 32K prompt and compare the numbers. X99 boards often do not
expose ReBAR; the 256 MiB mode is fully functional (all measurements above were
taken with it), so do not chase it.

## Gotchas

| Symptom | Cause / fix |
|---|---|
| `gid=993` lands on `kvm`, not `render` | `gid=` is the **container-side** GID. Debian 13: render=992, video=44. The scripts read them, do not copy the host's 993 |
| CT won't start: `Device /dev/dri/card0 does not exist` | `cardN` renumbers across boots (card0 → card1 after a cold boot). Do not pass `cardN`; ROCm compute needs only `/dev/kfd` + `renderD128` |
| GPU hits 110 °C / SDMA timeout / device lost | Fixed by the LACT profile above (86 °C, 5-min burn). If it returns, lower `max_core_clock` or repaste |
| `pp_od_clk_voltage` missing, `amd-smi` caps/fan refused | amdgpu overdrive is off. Add `amdgpu.ppfeaturemask=0xfff7ffff amdgpu.runpm=0` and reboot |
| LACT `acoustic_limit` rejected | max is **4950** RPM, not 5000 |
| LACT config `missing field daemon` | the config requires a `daemon:` section |
| Memory OC gives no tok/s | MCLK DPM stays at 772 MHz during decode — not memory-bound. Revert |
| `by-path` device node is created but nothing sees the GPU | Do not pass `/dev/dri/by-path/...`; the node is created at the literal path. Use `/dev/dri/renderD128` and the resolved `cardN` |
| `amdgpu-dkms` fails | Never install DKMS in the CT (or the host). The host kernel provides amdgpu/kfd; the engine carries its ROCm userland |
| Installation of ROCm inside the CT pulls a kernel module | Do not use `amdgpu-install` for this setup; `setup.sh` installs TheRock wheels into `.venv` |
| Two engines, OOM kill | Setup's engine is still running in tmux. Stop it before `systemctl start strata` |
| Strata much slower than prox-1 | Check the worker line (`13`) and that `/dev/kfd` is the container render node. Do not raise workers |
| Host memory pressure | Real CT use is ~43.6 GiB (76%) at 256K; `memory.current` (~56 GiB) includes ~13.6 GiB page cache. PVE's `mem` = `current - file`. 256K leaves host free 3.0 GiB; 200K (4.3) is safer |

## Rollback

```sh
pct stop 121
pct destroy 121          # deletes the 380 GB raw rootfs on nvme
```

The host's `amdgpu` stays untouched; no VFIO, no kernel flags to undo.

## Sources

- Proxmox `pct` reference: `dev[n]` syntax, `gid=` is container-side
- Proxmox wiki / admin guide: unprivileged containers, device passthrough
- Proxmox forum and 2026 LXC GPU guides: `dev0/1/2` on PVE 9, no idmap needed
- ROCm LXC write-ups: no DKMS in the container, `renderD128` stable, `by-path` trap
- LACT `docs/Overclocking-(AMD).md` (overdrive `ppfeaturemask`, `0x4000`),
  `docs/CONFIG.md` (fan curve, PMFW options, voltage offset), v0.10.1 headless
  Debian 13 package
- Local: `../gpu-passthrough/README.md` (prox-1 LXC, same GPU/CPU) and
  `../strata-vm/README.md` (why the VM path was abandoned)
