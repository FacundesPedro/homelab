# Troubleshooting

Work from the outside in: browser → API → service → container → GPU → host.
Most problems are one of four things: the container is not running, the IP
changed, the engine is still loading, or the GPU hit its thermal limit.

## The page does not open

```sh
pct status <CTID>                       # running?
pct exec <CTID> -- ip -4 addr show eth0 # what is the address?
pct exec <CTID> -- ss -ltnp | grep <PORT>
```

- If the container is stopped: `bash /root/strata-lxc/30-strata-control.sh start`.
- If the address changed: DHCP gave it a new lease. Reserve the MAC on the
  router, or fix the address in the container config.
- If nothing listens: the service is not running or bound to `127.0.0.1` only.
  Check `--host 0.0.0.0` in the run script.

## The service will not stay up

```sh
pct exec <CTID> -- systemctl status strata
pct exec <CTID> -- journalctl -u strata -n 200 --no-pager
pct exec <CTID> -- dmesg | tail -50
```

Look for, in this order:

| Message | Meaning | Fix |
|---|---|---|
| `cannot open /dev/kfd` | the device mapping is missing | re-check `dev0`/`dev1` in `/etc/pve/lxc/<CTID>.conf`, restart the CT |
| `hipErrorNoBinaryForGpu` / no `gfx` device | ROCm build does not match the card | rebuild the engine for your `gfx*` arch |
| `out of memory` / OOM kill | context + experts exceed RAM | lower the context or raise the container RAM |
| `address already in use` | two engines | stop the setup session before starting the service |
| `amdgpu: GPU reset` | thermal or driver crash | see the thermal section |

A second engine is the most common self-inflicted failure: `setup.sh` leaves
one running in tmux, and then the service starts another. Stop the tmux one.

## The first answer is slow

Normal. The expert cache is cold after a restart and fills as the model runs.
Warm it with one request and wait for it to finish. A 32K prompt can take about
a minute to read; the answer that follows is much faster.

## Answers are slow

Check, in order:

1. **Context size.** A larger context steals VRAM from the expert cache. Compare
   with the table in [20 — Container](../03-building-it/20-strata-lxc.md#context-sizing).
2. **Another request running.** The engine serves one at a time; a long prompt
   blocks the queue.
3. **Swap thrashing.** If the container is swapping heavily, the RAM is too
   small for the chosen model/context. Check `si/so` in `vmstat 1`.
4. **Clock collapse.** If the GPU is at its minimum clock during load, it is
   thermal-throttling. Check the junction temperature and the burn test.

## The GPU is hot / the host wedges

The reference card (blower RX 7900 XT) can reach **110 °C junction in seconds**
at stock settings. Symptoms: fans at maximum, clocks at minimum, then a driver
reset or the whole box unresponsive.

- Stop the load immediately: `pct stop <CTID>` (or `systemctl stop strata`
  inside).
- Wait for the card to cool before restarting.
- Apply or re-check the undervolt and fan curve in
  [`undervolt/`](../undervolt/README.md).
- If the card is already wedged, a cold power cycle is the only recovery. A
  smart plug plus "Restore on AC Power Loss = Power On" makes it remote.

Do not repeatedly restart into the same thermal limit; fix the profile first.

## `content: null`

The model spent the whole token budget thinking. Raise `max_tokens` to 256+ or
set `reasoning_budget_tokens` so the answer has room. This is not an error.

## The model ignores tools

Native tool calling is limited. Use chat or the `plan` agent; do not expect the
`build` agent to work reliably. See [40 — Clients](../03-building-it/40-clients.md#tools).

## The API rejects the Host header

Bind the service to `0.0.0.0` and add the address/hostname to
`STRATA_ALLOWED_HOSTS`:

```
Environment=STRATA_ALLOWED_HOSTS=<CT_IP>,<CT_HOSTNAME>
```

Then `systemctl daemon-reload && systemctl restart strata`.

## Memory looks wrong in the Proxmox UI

The UI reports the real value (page cache excluded). If you are reading
`memory.current`, it includes reclaimable cache and looks much higher. Use:

```sh
cat /sys/fs/cgroup/lxc/<CTID>/memory.stat      # on the host
```

or the monitor script:

```sh
SAMPLES=10 INTERVAL=2 bash /root/strata-lxc/ram-monitor.sh
```

A container at ~75–80% real usage is expected. Only `memory.events` with
`oom_kill` or a rising swap-in rate is a problem.

## The GPU disappeared after a VM stop/start

That is the **Navi 31 reset bug** on the passthrough path. It does not happen
with the LXC, which shares the host driver. If you are still on the VM path,
the only recovery is a cold power cycle; see
`proxmox/strata-vm/README.md` and move to the LXC.

## The container will not start after a reboot

Most likely a stale device entry: `card0`/`card1` renumbered. Do not pass
`cardN`; keep only:

```
dev0: /dev/kfd,gid=<render>
dev1: /dev/dri/renderD128,gid=<render>
```

Check with `pct config <CTID>` and `pct start <CTID>` for the exact error.

## Updating broke the context or the binding

`setup.sh` regenerates the run script and the JSON. Re-add:

- `--host 0.0.0.0 --port <PORT>` in the run script;
- `--max-context <CONTEXT>` in both `args` and `args_written` in the JSON.

Keep a backup of the working JSON before any update.

## Collecting a report

```sh
pveversion -v
pct config <CTID>
pct exec <CTID> -- systemctl status strata --no-pager
pct exec <CTID> -- journalctl -u strata -n 200 --no-pager
dmesg | grep -iE 'amdgpu|GPU reset|oom|hung task' | tail -50
lact cli info
sensors 2>/dev/null || true
```

Include the context value, the model, the quantization and the card model.
