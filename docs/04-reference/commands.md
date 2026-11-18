# Commands

Host commands run as root on the Proxmox host; the `opencode` commands run on
the client. Replace `<CTID>`, `<CT_IP>`, `<PORT>`, `<GPU_PCI>`,
`<STORAGE_PATH>` and `<RUN_SCRIPT>` with your values.

## Container

```sh
pct status <CTID>
pct start <CTID>
pct stop <CTID>
pct enter <CTID>
pct exec <CTID> -- <command>
pct config <CTID>
pct list
```

The helper (set `CTID` if it is not 121):

```sh
bash /root/strata-lxc/30-strata-control.sh start|stop|restart|status|logs
```

## Strata

```sh
pct exec <CTID> -- systemctl status strata
pct exec <CTID> -- systemctl restart strata
pct exec <CTID> -- journalctl -u strata -n 100 --no-pager
curl -s http://<CT_IP>:<PORT>/health
curl -s http://<CT_IP>:<PORT>/v1/models
```

## Verification and benchmarks

```sh
bash /root/strata-lxc/20-verify-strata.sh
python3 docs/03-building-it/bench-prompt.py --url http://<CT_IP>:<PORT>/v1/chat/completions --target 8192
python3 docs/03-building-it/bench-prompt.py --url http://<CT_IP>:<PORT>/v1/chat/completions --target 32768
SAMPLES=30 INTERVAL=2 bash /root/strata-lxc/ram-monitor.sh
bash /root/burn.sh                       # 30 s
REPEAT=10 bash /root/burn.sh             # 5 min
```

## GPU / LACT

```sh
lact cli info
lact cli list-gpus
systemctl status lactd
cat /etc/lact/config.yaml
cat /sys/class/drm/card*/device/pp_od_clk_voltage
```

The hwmon numbers vary by board. Find the GPU's hwmon directory first, then
read the sensors:

```sh
for h in /sys/class/hwmon/hwmon*; do
  echo "$h $(cat "$h/name" 2>/dev/null)"
done
H=/sys/class/hwmon/hwmon2          # the one named amdgpu
cat "$H/temp1_input"               # edge, millidegrees
cat "$H/temp2_input"               # junction
cat "$H/fan1_input"
cat /sys/class/drm/card*/device/mem_info_vram_used
cat /sys/class/drm/card*/device/mem_info_vram_total
```

## Host / memory

```sh
NODE=$(hostname -s)
pvesh get "/nodes/$NODE/lxc/<CTID>/status/current" --output-format json
cat /sys/fs/cgroup/lxc/<CTID>/memory.current
cat /sys/fs/cgroup/lxc/<CTID>/memory.stat | grep -E '^(anon|file|inactive_file|active_file) '
cat /sys/fs/cgroup/lxc/<CTID>/memory.events
free -m
pvesm status
df -h / <STORAGE_PATH>
```

Remember: PVE's real usage is `memory.current - memory.stat.file`; the UI uses
that, while the cgroup total includes the page cache.

## Context

```sh
pct exec <CTID> -- cat /opt/Strata/strata-iq3_s.json
pct exec <CTID> -- grep -A1 -- '--max-context' /opt/Strata/strata-iq3_s.json
pct exec <CTID> -- cp -a /opt/Strata/strata-iq3_s.json.200k /opt/Strata/strata-iq3_s.json
pct exec <CTID> -- cp -a /opt/Strata/strata-iq3_s.json.bak  /opt/Strata/strata-iq3_s.json
pct exec <CTID> -- systemctl restart strata
```

Adjust the file names if your model profile is called something else.

## Diagnostics

```sh
dmesg | grep -iE 'amdgpu|GPU reset|oom|hung task'
pct exec <CTID> -- free -m
pct exec <CTID> -- ps -eo rss,comm --sort=-rss | head
pct exec <CTID> -- /opt/Strata/.venv/bin/rocminfo | grep -m1 gfx
pct exec <CTID> -- ls -l /dev/kfd /dev/dri/
lspci -nnk -s <GPU_PCI>
lact cli info | grep -iE 'resizable|PCIe Link'
```

## OpenCode (client)

```sh
opencode models | grep strata
opencode run -m strata-lan/qwen38-iq3s --agent plan "hello"
```

## Persistence

```sh
pct exec <CTID> -- systemctl is-enabled strata
pct config <CTID> | grep -E '^(onboot|dev|memory|cores|rootfs):'
systemctl is-enabled lactd
cat /proc/cmdline
```
