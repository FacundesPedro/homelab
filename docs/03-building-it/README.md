# Building it

The technical path, from an empty host to a working LAN endpoint. It assumes
root on the Proxmox host. The exhaustive, idempotent scripts live in
`proxmox/strata-lxc/`; this chapter explains the order, the versions and the
decisions so the same result can be reproduced on different hardware.

## What you need

The numbers in the last column are the **reference deployment**. Treat them as
a worked example: the requirements column is what actually matters.

### Hardware

| Requirement | Why | Reference |
|---|---|---|
| AMD GPU supported by ROCm, with enough VRAM for the model slice + KV + buffers | the compute device | RX 7900 XT, 20 GB, `gfx1100` |
| CPU with enough physical cores | the offloaded experts run on the CPU | Xeon E5-2697 v3, 14C/28T |
| RAM ≥ the offloaded expert arena + OS | experts live in host RAM in low-RAM mode | 62 GiB |
| Fast disk ≥ model + working copy | avoids reload stalls | 477 GB NVMe |
| Wired 1 GbE, DHCP | LAN access | — |
| A way to cold-cycle power | recovery from a GPU wedge | smart plug (recommended) |

Order of thumb for sizing: **the model must fit in RAM, the KV cache must fit
in VRAM, and both need headroom.** A 20 GB card can serve a ~79 GiB IQ3_S model
only because the experts are streamed from RAM and only a fraction is cached on
the GPU. A smaller model or a smaller quantization needs proportionally less.

### Host

- Proxmox VE 9.x on Debian 13 (the reference is **9.2.28**, kernel
  **7.0.14-29-pve**).
- The `pve-no-subscription` repo.
- GPU kernel flags (see [10 — Host](10-host.md#kernel-flags)):
  overdrive enabled, runtime PM off, ASPM off.
- A fast directory storage for the container rootfs. The reference uses
  `<STORAGE>` = `nvme`, mounted at `<STORAGE_PATH>` = `/mnt/nvme`.
- BIOS: Above 4G Decoding on, ReBAR if the board has it, CSM off, and
  **Restore on AC Power Loss = Power On** if you want remote recovery.

### Container

- A Debian 13 template (`<TEMPLATE>`, auto-detected by the create script).
- An **unprivileged** LXC with:
  - RAM sized to the model's CPU-side arena + headroom (reference: 56 GiB);
  - swap (reference: 4 GiB);
  - all CPU threads (reference: 28), so the engine can pick its own workers;
  - rootfs on the fast storage (reference: 380 GB);
  - `fuse=1,nesting=1`;
  - `lxc.prlimit.memlock: unlimited`;
  - `/dev/kfd` and `/dev/dri/renderD128` mapped in (see
    [20 — Container](20-strata-lxc.md)).

### Model and engine

- Strata from `https://github.com/Niko1221/Strata`, built with
  `./setup.sh --backend hip`.
- A GGUF model that fits the sizing rule above. The reference uses
  **Qwen3.8-Flash-Next GSQ-RCO IQ3_S** (~84 GB download, ~134 GiB on disk with
  the low-RAM copy).
- The engine's venv carries its own **ROCm** build; no system ROCm, no DKMS.
- KV cache: 8-bit (q8/int8). Context: start at 32K, raise in steps.
- Vision: on, encoder on CPU unless you have VRAM to spare.

### GPU tuning

- LACT headless (`lactd`), the version matching your distro.
- A voltage/fan profile that keeps the junction **below 90 °C** under sustained
  load. The reference profile and the full method are in
  [`undervolt/`](../undervolt/README.md).

### Client

- Any OpenAI-compatible client. The reference uses OpenCode with the
  `@opencode/ai/providers/openai-compatible` provider.

## The order

1. Install Proxmox, the no-subscription repo, the storage and the network
   ([10 — Host](10-host.md)).
2. Set the BIOS, especially **Restore on AC Power Loss** if the machine has no
   BMC.
3. Add the GPU kernel flags; reboot ([10 — Host](10-host.md#kernel-flags)).
4. Install LACT and apply a safe undervolt **before the first model load**. A
   stock blower card can hit its thermal limit in seconds and wedge.
5. Run the burn test; require the junction **< 90 °C** over 5 minutes
   ([`undervolt/`](../undervolt/README.md)).
6. Create the container ([20 — Container](20-strata-lxc.md)).
7. Run `setup.sh`, pick the model, the context and the KV quantization; let it
   download and build.
8. Install and enable the service, bind `0.0.0.0`, verify
   ([30 — Verification](30-verification.md)).
9. Add the client; run the end-to-end tests ([40 — Clients](40-clients.md)).
10. Raise the context one step at a time until VRAM is ~95% used, then keep a
    backup of every working profile.

## Time and space

| Step | Cost (reference) |
|---|---|
| PVE + host prep | ~1 hour, one reboot |
| LACT + burn tests | ~30 minutes |
| Container create | ~5 minutes |
| Model download | ~84 GB; depends on the link |
| Engine build | ~10 GB ROCm + compile on 28 cores; tens of minutes |
| Disk | ~134 GiB for the model and its working copy |

## What can go wrong (read before you start)

- **Thermals first.** Do not load the model before the undervolt and the burn
  test. The reference card hits 110 °C junction in ~4 seconds at stock settings.
- **The VM path.** A GPU-passthrough VM hits the **Navi 31 reset bug** (the card
  disappears after a stop/start and needs a cold power cycle) and pins the
  guest's RAM in the host. The LXC is the supported path; the record is in
  `proxmox/strata-vm/`.
- **No BMC.** A wedged GPU can need a cold power cycle. A smart plug plus
  "Restore on AC Power Loss = Power On" makes that remote.
- **No auth by default.** The API is open on the LAN. Add an API key or a proxy
  if that is not acceptable.
- **One request at a time.** Do not run a benchmark and a chat at once, and do
  not start a second engine next to the service: they will share the RAM and
  one will be OOM-killed.
- **Do not pass `cardN` into the container.** The card number can change across
  boots; pass `/dev/kfd` and `/dev/dri/renderD128` only.
