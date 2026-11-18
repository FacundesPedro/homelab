# Verifying it

Run on the Proxmox host as root unless a command says otherwise. Replace
`<CTID>`, `<CT_IP>`, `<GPU_PCI>`, `<STORAGE_PATH>` and `<PORT>` with your
values.

## The quick checks

```sh
bash /root/strata-lxc/20-verify-strata.sh
pct exec <CTID> -- systemctl is-active strata
pct exec <CTID> -- /opt/Strata/.venv/bin/rocminfo | grep -m1 gfx
lact cli info | grep -iE 'resizable|PCIe Link'
```

`20-verify-strata.sh` also accepts `CTID`, `API` and `GPU_PCI` from the
environment. Expected:

- the service active;
- the engine reports your GPU architecture (`gfx1100` on RDNA 3, `gfx1030` on
  RDNA 2, and so on);
- the GPU bound to `amdgpu`;
- `/health` reports `loaded: true` and the intended `max_context`.

## The API

```sh
curl -s http://<CT_IP>:<PORT>/health
curl -s http://<CT_IP>:<PORT>/v1/models
curl -s http://<CT_IP>:<PORT>/v1/chat/completions \
  -H 'Content-Type: application/json' -H 'Authorization: Bearer x' \
  -d '{"model":"strata","messages":[{"role":"user","content":"Say hello"}],"max_tokens":64,"reasoning_budget_tokens":32}'
```

The last one returns `content` and a `timings` object. A 64-token cap can still
be all thinking; use 256+ for a real answer.

## The real memory

The Proxmox UI's memory value is the real one: PVE reports
`memory.current - memory.stat.file`, i.e. page cache excluded.
`memory.current` alone can look ~10–15 GiB higher.

```sh
SAMPLES=30 INTERVAL=2 bash /root/strata-lxc/ram-monitor.sh
```

It prints the PVE/UI value, `anon`, page cache, engine RSS, host/CT free, VRAM
and the GPU junction/power. Set `CTID` if yours is not 121.

What healthy looks like:

- real usage flat during a request (the context lives in VRAM);
- no `oom` or `oom_kill` in
  `/sys/fs/cgroup/lxc/<CTID>/memory.events`;
- host has at least ~1–2 GiB free and some available;
- VRAM below ~95% of total.

## The prompt benchmark

```sh
python3 proxmox/strata-lxc/bench-prompt.py --url http://<CT_IP>:<PORT>/v1/chat/completions --target 8192
python3 proxmox/strata-lxc/bench-prompt.py --url http://<CT_IP>:<PORT>/v1/chat/completions --target 32768
```

Reference results on a 20 GB RX 7900 XT with IQ3_S:

| Context | 8K prompt | 32K prompt | Decode (84 tok) |
|---|---:|---:|---:|
| 128K | 602 tok/s (16K 607) | — | 45–54 tok/s |
| 200K | 572 | 595 | ~30–40 |
| 256K | 552 | 572 | 34.6 |

Your absolute numbers will differ with the card and the model. What matters is
the **shape**: prefill stays roughly flat with context, decode drops as the
expert cache shrinks, and RAM stays flat.

## The GPU burn (after the undervolt)

See [`undervolt/`](../../undervolt/README.md). Acceptance: a **5-minute** burn with
the junction **< 90 °C** and no clock collapse.

```sh
scp undervolt/burn.sh root@<HOST_IP>:/root/burn.sh   # once
bash /root/burn.sh             # 30 s
REPEAT=10 bash /root/burn.sh   # 5 min
```

The reference profile lands at **86 °C, 145 W, 93 launches** over 5 minutes.

## The client end-to-end test

```sh
opencode models | grep strata
opencode run -m strata-lan/qwen38-iq3s --agent plan "Say hello from the LAN. Do not use tools."
```

Adjust the provider/model names to your config.

## The context sanity check

- `/health`: `max_context` equals the value you set.
- The generated JSON: `--max-context` in both `args` and `args_written`.
- The client: its `limit.context` matches.
- Real RAM and VRAM match your recorded table.
- The previous context backups exist.
