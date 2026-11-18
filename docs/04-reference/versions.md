# Versions and dependencies

Two sections: the **generic dependency list** (what must be present for any
reproduction) and the **tested reference stack** (one exact combination that is
known to work).

## What must be present

| Dependency | Needed for | Notes |
|---|---|---|
| Proxmox VE 9.x | host and LXC | 8.x works but the commands here were tested on 9.2 |
| Debian 13 template | container userspace | any current Debian/Ubuntu works; package names differ |
| Kernel `amdgpu` + `kfd` | GPU compute | the host kernel supplies both; no DKMS inside the container |
| ROCm userspace for your GPU arch | the engine | provided by the engine's own venv build; must match `gfx*` |
| `git`, compiler, Python 3.11+ | building the engine | installed by the create script |
| Strata | inference engine + web UI | upstream `Niko1221/Strata` |
| A GGUF model + tokenizer | the model | quantization chosen to fit RAM/VRAM |
| LACT (headless) | undervolt, clocks, fan | optional but strongly recommended for blower cards |
| An OpenAI-compatible client | using it | OpenCode, curl, any SDK |
| Fast disk ≥ model size | storage | NVMe preferred |

The GPU architecture matters: the engine is built for a `gfx*` target (for
example `gfx1100` for RDNA 3, `gfx1030` for RDNA 2). Check with:

```sh
pct exec <CTID> -- /opt/Strata/.venv/bin/rocminfo | grep -m1 gfx
```

## Tested reference stack (18 Nov 2026)

Everything below was captured from the running reference box. It is a record,
not a minimum.

### Host / platform

| Component | Version / value |
|---|---|
| Proxmox VE | 9.2.28 |
| Debian | 13.6 (trixie) |
| Kernel | 7.0.14-29-pve |
| Board | JGINYUE X99-TI D4 PLUS, BIOS 5.11, no BMC |
| CPU | Intel Xeon E5-2697 v3, 14C/28T |
| RAM | 62 GiB |
| GPU | ASRock RX 7900 XT Creator, 20 GB, VBIOS `022.001.002.039.000001` (2024/05/29) |
| GPU link | PCIe **Gen3 x16** (the X99 platform) |
| ReBAR | **Disabled**, 256 MiB CPU-accessible VRAM |
| NVMe | Solid State Storage CL4-8D512, 477 GB, ext4 `/mnt/nvme` |
| OS disk | 240 GB SATA SSD, LVM (36 GB root + 175 GB thin + 8 GB swap) |
| Kernel flags | `iommu=pt pcie_aspm=off amdgpu.ppfeaturemask=0xfff7ffff amdgpu.runpm=0` |

### Container

| Component | Version / value |
|---|---|
| CT | **121** `strata-2`, unprivileged |
| Template | `debian-13-standard_13.6-1_amd64.tar.zst` |
| CPU / RAM | 28 cores / 56 GiB + 4 GiB swap |
| Rootfs | 380 GB raw on `nvme` (`nvme:121/vm-121-disk-0.raw`) |
| Devices | `/dev/kfd`, `/dev/dri/renderD128` (container GID 992) |
| Extras | `fuse=1,nesting=1`, `lxc.prlimit.memlock: unlimited` |
| Network | DHCP; currently `192.168.3.66/24`, MAC `BC:24:11:5E:73:CA` |

### Strata / engine / model

| Component | Version / value |
|---|---|
| Strata source | `https://github.com/Niko1221/Strata` |
| Strata revision | `c77572806996349b49995e4f98d41b5294d36a21` (2026-11-16) |
| App / setup | 0.2.15 lineage |
| Engine | **0.1.61**, `local-hip`, `gfx1100`, vision `cpu` (`/opt/Strata/engine/BUILD.json`) |
| ROCm (bundled) | **7.10.0a20251120** (`rocm`, `rocm-sdk-core`, `rocm-sdk-devel`, `rocm-sdk-libraries-gfx110X-dgpu`) |
| Python packages | numpy 2.5.3, pillow 13.0.0, requests 2.34.2, textual 8.2.8 (plus the setup's pins) |
| Model | Qwen3.8-Flash-Next GSQ-RCO **IQ3_S** (ISTA-DASLab) |
| Model files | `Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf` (52 GB) + `...-00002-of-00002.gguf` (27 GB) |
| Model download | ~84 GB (the setup's figure); the files are ~79 GiB |
| Data directory | ~134 GiB (model + low-RAM expert copy + packs + MTP + vision) |
| Context / KV | **256K** (262144) / int8 (q8) |
| MTP | `/opt/Strata-data/mtp/rt` |
| Vision | `mmproj-Qwen3.8-Flash-Next-BF16.gguf`, CPU, 14 threads |
| Runtime | `strata.service` enabled, `--host 0.0.0.0 --port 8080` |

### GPU tuning

| Component | Version / value |
|---|---|
| LACT | **0.10.1** headless, Debian 13 |
| Package | `lact-headless-0.10.1-0.amd64.debian-13.deb` |
| SHA-256 | `a48432a70004a8015594041676651bb663c9f2a31406e0a736ae0d676cc72b6c` |
| LACT deps | `vulkan-tools`, `libdrm2`, `libdrm-amdgpu1`, `hwdata`, `clinfo` |
| Overdrive | `amdgpu.ppfeaturemask=0xfff7ffff` (OD bit `0x4000`); stock PVE value `0xfff7bfff` |
| Runtime PM | `amdgpu.runpm=0` |
| Profile | `voltage_offset: -100` mV, `max_core_clock: 2760`, `power_cap: 231`, PMFW fan |
| Burn | 5-min 86 °C / 145 W / 93 launches (stock 110 °C / 250 W / 98) |
| Idle | 38 °C / 12 W / ~1,900 RPM |

### Client

| Component | Version / value |
|---|---|
| OpenCode | 2.3.0 |
| Provider package | `@opencode/ai/providers/openai-compatible` |
| Provider / model | `strata-lan` / `qwen38-iq3s` → `qwen3.8-flash-next-iq3_s` |
| Context limit | 262144 |
| Endpoint | `http://192.168.3.66:8080/v1` |
| Auth | none (`api_key: false`) |

### Network

| | |
|---|---|
| Host | `192.168.3.56/24`, gw/DNS `192.168.3.1` |
| CT | `192.168.3.66/24` (DHCP; reserve the MAC on the router) |
| API | `0.0.0.0:8080` |
| Firewall | PVE firewall disabled; the API is open on the LAN |

### Backups and configs

| Path | What |
|---|---|
| `/opt/Strata/strata-iq3_s.json` | current profile (256K) |
| `/opt/Strata/strata-iq3_s.json.200k` | 200K profile |
| `/opt/Strata/strata-iq3_s.json.bak` | 128K profile |
| `/etc/lact/config.yaml` | the GPU profile |
| `/etc/default/grub` | the kernel flags |
| `/root/strata-lxc/` | the scripts and the runbook |

## Upstream links

- Strata: <https://github.com/Niko1221/Strata>
- LACT: <https://github.com/ilya-zlobintsev/LACT>
- Model: Qwen3.8-Flash-Next GSQ-RCO IQ3_S by ISTA-DASLab (via the setup)
- ROCm: TheRock `gfx110X-dgpu` wheels, 7.10.0a20251120
- Debian template: `debian-13-standard_13.6-1_amd64.tar.zst` (Proxmox `pveam`)
