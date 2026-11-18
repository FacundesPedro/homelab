# Strata — self-hosted LLM server

Documentation for running **Strata** (a local inference engine) with a large
quantized model on an **AMD GPU inside a Proxmox LXC**, reachable from the LAN
through a web page and an OpenAI/Anthropic-compatible API.

The documentation has two halves: the first is for people who only want to use
the server, the second for whoever builds, tunes or repairs it. Read only what
you need.

## Start here

| If you want to… | Read | Level |
|---|---|---|
| understand what this is | [01 — What this is](01-what-this-is.md) | plain language |
| use it (browser, OpenCode, API) | [02 — Using it](02-using-it.md) | plain language |
| rebuild it from scratch | [03 — Building it](03-building-it/README.md) | technical |
| fix something | [04 — Troubleshooting](04-reference/troubleshooting.md) | technical |
| change the GPU voltage / fan / clocks | [`undervolt/`](../undervolt/README.md) | technical |
| look up a command | [04 — Commands](04-reference/commands.md) | reference |
| look up the tested versions | [04 — Versions](04-reference/versions.md) | reference |

## Conventions

These instructions are written for **any compatible system**. Angle-bracket
values are placeholders; the scripts in `proxmox/strata-lxc/` accept the same
names as environment variables, so the defaults can be overridden without
editing anything.

| Placeholder | Script variable | Meaning |
|---|---|---|
| `<HOST_IP>` | — | Proxmox host address |
| `<CT_IP>` | — | Strata container address |
| `<CTID>` | `CTID` | container ID |
| `<CT_HOSTNAME>` | `CT_HOSTNAME` | container host name |
| `<GPU_PCI>` | `GPU_PCI` | AMD GPU PCI address (`lspci`) |
| `<STORAGE>` | `STORAGE` | fast storage for the rootfs |
| `<STORAGE_PATH>` | `NVME_PATH` | mount point of that storage |
| `<BRIDGE>` | `BRIDGE` | network bridge |
| `<TEMPLATE>` | — | Debian template (auto-detected) |
| `<PORT>` | — | API/web port (default `8080`) |
| `<CONTEXT>` | — | context size in tokens (`--max-context`) |
| `<MODEL>` | — | the GGUF model and quantization |

Use your own values everywhere. Where the documentation gives a number
(VRAM, RAM, temperature, speed), it is measured on the **reference deployment**
and is an example, not a requirement.

## Reference deployment

Everything in this repository was measured on one machine. It is kept as a
concrete, known-good example:

| Placeholder | Reference value |
|---|---|
| `<HOST_IP>` | `192.168.3.56` |
| `<CT_IP>` | `192.168.3.66` |
| `<CTID>` | `121` |
| `<CT_HOSTNAME>` | `strata-2` |
| `<GPU_PCI>` | `05:00.0` |
| `<STORAGE>` | `nvme` |
| `<STORAGE_PATH>` | `/mnt/nvme` |
| `<BRIDGE>` | `vmbr0` |
| `<TEMPLATE>` | `debian-13-standard_13.6-1_amd64.tar.zst` |
| `<PORT>` | `8080` |
| `<CONTEXT>` | `262144` (256K) |
| `<MODEL>` | Qwen3.8-Flash-Next, IQ3_S |

| | |
|---|---|
| Hardware | Xeon E5-2697 v3, 62 GiB RAM, ASRock RX 7900 XT 20 GB, 477 GB NVMe |
| Host | Proxmox VE 9.2.28, Debian 13.6, kernel 7.0.14-29-pve |
| Container | Debian 13, 56 GiB RAM, 28 cores, 380 GB rootfs on NVMe |
| Speed | ~552–572 tok/s prompt, ~30–54 tok/s answer |
| GPU tuning | −100 mV / 2760 MHz / 231 W cap (see `undervolt/`) |
| Auth | none; LAN only (`api_key: false`) |

The full version list is in [04 — Versions](04-reference/versions.md).

## The repository

| Path | What |
|---|---|
| `docs/` | this documentation |
| `undervolt/` | GPU undervolt/overclock method, LACT config, burn test, results |
| `proxmox/strata-lxc/` | the reproducible scripts and the exhaustive runbook |
| `proxmox/prox-2/` | the reference host build notes (PVE, storage, network) |
| `proxmox/gpu-passthrough/` | an earlier container on a different host (same GPU) |
| `proxmox/strata-vm/` | the reverted VM + VFIO attempt, kept as the record |

## Non-technical glossary

| Word | Plain meaning |
|---|---|
| Proxmox / PVE | the operating system that runs the server and its guests |
| LXC / container | a lightweight box inside the server; it shares the host kernel |
| VM | a full virtual computer; heavier than a container |
| GPU / card | the graphics card, the part that does the AI math |
| VRAM | the GPU's own memory |
| RAM | the server's working memory |
| model | the "brain" file (a GGUF file in this setup) |
| context | how much text the model can read at once, in tokens |
| token | a word piece; roughly 0.75 words |
| KV cache | the model's short-term memory of the conversation |
| prefill | reading the prompt; "prompt tok/s" |
| decode | writing the answer; "generation tok/s" |
| undervolt | running the GPU at a lower voltage so it runs cooler |
| ReBAR | a BIOS feature that lets the CPU see more of the GPU's memory |
| LACT | the tool that applies the undervolt and the fan curve |

## Security

There is **no login**. Anyone on the LAN can use the model. Keep the server on
the trusted network, do not forward the port on the router, and see the API-key
note in [02 — Using it](02-using-it.md#security) if that is not enough.

## Reference deployment state (18 Nov 2026)

- Context **256K**, q8/int8 KV; backups `.200k` (200K) and `.bak` (128K).
- LACT profile **−100 mV / 2760 MHz / 231 W**; 5-minute burn **86 °C**.
- `strata.service` enabled, binds **0.0.0.0:8080**.
- OpenCode provider `strata-lan/qwen38-iq3s`, context limit 262144.
