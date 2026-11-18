# Undervolt / overclock (AMD GPU)

This folder is the GPU-tuning part of the build: why the card needs it, how to
find a stable profile, and the exact profile used in the reference deployment.
The method applies to any AMD GPU that LACT supports; the numbers do not.

**Do this before the first model load.** A stock blower card can hit its
thermal limit in seconds, and a wedged GPU means a cold power cycle.

## Why

The reference card is an ASRock RX 7900 XT Creator with a blower cooler. At
stock settings it draws ~250 W, and the **junction (hotspot) temperature reaches
110 °C in about 4 seconds** under full load. The driver then resets or the
machine hangs.

The cooler is the limit, not the silicon. Two software changes fix it:

1. **Less heat**: cap the power and lower the voltage.
2. **More airflow**: a higher, earlier fan ramp.

With the reference profile the same 5-minute load stays at **86 °C junction,
145 W**, and the card is stable. A repaste and better case airflow are still
worth doing, but the software profile is what makes the card usable.

## Before you start

- The **overdrive** bit must be enabled, or the driver rejects voltage, clock
  and power changes. Check the kernel command line:

  ```sh
  cat /proc/cmdline | tr ' ' '\n' | grep ppfeaturemask
  ```

  It must include `0xfff7ffff` (the `0x4000` bit is overdrive). Proxmox's stock
  value is often `0xfff7bfff`. Change it in `/etc/default/grub`, run
  `update-grub`, reboot. See
  [10 — Host](../03-building-it/10-host.md#kernel-flags).

- Confirm the driver exposes the tuning interface:

  ```sh
  cat /sys/class/drm/card*/device/pp_od_clk_voltage
  ```

  You should see `OD_SCLK`, `OD_MCLK` and voltage ranges. If it says the file is
  not accessible, overdrive is still off.

- Install LACT headless and enable `lactd`:

  ```sh
  apt-get install -y vulkan-tools libdrm2 libdrm-amdgpu1 hwdata clinfo
  # download the headless .deb for your Debian release from the LACT releases
  apt-get install -y ./lact-headless-*.deb
  systemctl enable --now lactd
  lact cli list          # find your GPU id
  lact cli info          # model, VRAM, current link
  lact cli power-limit get
  ```

  The reference uses LACT **0.10.1**; newer versions are expected to work but
  the YAML schema can change, so check `lact cli info` after an upgrade.

- Stop the model service while testing, so the load and the measurements are
  clean:

  ```sh
  bash /root/strata-lxc/30-strata-control.sh stop
  ```

## The method

Change **one variable at a time**, and run the burn after each change. Keep a
note of every combination; the card may be stable at idle and crash only under
sustained load.

Suggested order (safest first):

| Step | Change | What to watch |
|---|---|---|
| 1 | power cap | junction falls immediately; performance loss is small until the cap is far below stock |
| 2 | fan / PMFW | junction and fan RPM; noise |
| 3 | voltage offset | junction and stability; too much gives a driver reset |
| 4 | max core clock | performance per watt; too high just hits the power cap |
| 5 | memory clock | usually **not** worth it on this workload; verify the memory clock actually moves |

Acceptance for a profile:

- **5 minutes** of continuous load;
- junction **< 90 °C** (leave margin under the 110 °C limit);
- no `amdgpu` reset, no hang, no application error;
- clocks do not collapse to the minimum for the whole run;
- the fan is within a noise level you can live with.

If the card resets or the screen/SSH session dies, the profile is too
aggressive: raise the voltage offset (less negative) or lower the clock, then
retest. A reset means a cold power cycle on this platform.

## The reference profile

LACT **0.10.1**, headless, `/etc/lact/config.yaml`. A copy-paste version is in
[`config.example.yaml`](config.example.yaml):

```yaml
version: 7
daemon:
  log_level: info
  disable_clocks_cleanup: false
apply_settings_timer: 5
gpus:
  1002:744C-1849:5332-0000:05:00.0:
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
current_profile: null
auto_switch_profiles: false
```

What each line does:

| Setting | Meaning |
|---|---|
| `power_cap: 231` | board power limit in watts; the biggest single lever on temperature |
| `voltage_offset: -100` | core voltage offset in mV; less voltage at the same clock = less heat |
| `max_core_clock: 2760` | upper clock bound in MHz; a ceiling, not a fixed clock |
| `performance_level: auto` | lets the driver manage DPM states instead of pinning a level |
| `pmfw_options` | the driver's own fan controller (see below) |
| `fan_control_enabled: false` | intentional: PMFW drives the fan, LACT does not add a curve on top |
| `acoustic_limit: 4950` | maximum fan RPM accepted by PMFW (the driver's cap) |
| `acoustic_target: 2500` | RPM the controller aims for while temperatures are in range |
| `minimum_pwm: 30` | fan never drops below 30% |
| `target_temperature: 80` | the temperature PMFW regulates toward |
| `zero_rpm: false` | fan always spinning; keeps VRAM and the hotspot from soaking |

Why not a fixed fan curve: the reference uses the GPU's **PMFW** controller,
which reacts to the hotspot and the memory temperature. A static curve was
noisier and no cooler at the same junction.

Why not memory overclock: 1300 MHz was applied, but the memory DPM stayed at
772 MHz during decode and throughput did not change — the workload is not
memory-bound. Reverted to the stock 1250 MHz. Verify with:

```sh
cat /sys/class/drm/card*/device/pp_dpm_mclk
```

## Apply it

1. Edit `/etc/lact/config.yaml` (use `lact cli list` to find your GPU key; the
   first field is the PCI address).
2. Restart the daemon:

   ```sh
   systemctl restart lactd
   ```

3. Confirm the driver accepted it:

   ```sh
   cat /sys/class/drm/card*/device/pp_od_clk_voltage
   lact cli info | grep -iE 'power|clock'
   lact cli power-limit get
   ```

   The power limit should read back as the value you set. If LACT logs an error,
   check `journalctl -u lactd -n 50`.

4. Run the burn (below), then start the service again.

LACT re-applies the profile at boot through `lactd`. After a reboot, confirm the
power limit and the junction under load once more; a kernel or driver update can
reset the overdrive bit.

## The burn test

`burn.sh` runs a sustained HIP compute loop and samples the amdgpu sensors. Copy
it to the host once (the host has no repo checkout), then run it there; it uses
the container's `hipcc` when the host has none:

```sh
scp docs/undervolt/burn.sh root@<HOST_IP>:/root/burn.sh
ssh root@<HOST_IP>
bash /root/burn.sh             # 30 s
REPEAT=10 bash /root/burn.sh   # 5 min
```

If the repository is already on the host, `bash docs/undervolt/burn.sh` works
the same way.

Options (environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `CTID` | `121` | container that provides `hipcc` |
| `STRATA_DIR` | `/opt/Strata` | engine directory |
| `VENV` | `$STRATA_DIR/.venv` | venv with `hipcc` and the ROCm libraries |
| `RUN_SECONDS` | `30` | seconds per repetition |
| `REPEAT` | `1` | repetitions; `10` = 5 minutes |
| `LIMIT_C` | `105` | junction abort threshold |
| `FORCE` | `0` | set to `1` to test while `strata` is running |

The script refuses to run while `strata.service` is active unless `FORCE=1`,
because the model and the burn would compete for the GPU and the RAM.

It prints the minimum, average and peak junction, the peak power, and the
number of kernel launches. Record them next to the profile.

### Reference results

| State | Junction (5 min) | Power | Launches |
|---|---:|---:|---:|
| Stock | 110 °C in ~4 s, reset | ~250 W | 98 |
| **Final profile** | **86 °C** | **145 W** | **93** |
| Idle | 38 °C | 12 W | — |

The final profile is stable across repeated runs. The edge temperature stays
well below the junction; the junction is the number that matters on this card.

The launch count depends on the burn kernel: the 93 above came from the
historical kernel used during the tuning sweep, and this `burn.sh` will report
a different number for the same duration. Compare **junction and power**, not
launches, when you repeat the test.

## Gotchas

- **`acoustic_limit` max is 4950.** Higher values are rejected or clamped.
- **A `daemon:` section is required.** A config without it fails to load.
- **Use `pmfw_options` with `fan_control_enabled: false`.** Enabling a LACT
  curve on top of PMFW fights the driver.
- **`lact cli` has no generic `set`.** Use `lact cli power-limit set` for the
  power cap; edit the YAML for voltage, clocks and the fan, then restart
  `lactd`.
- **Overdrive off looks like "the file is not accessible".** Fix the kernel
  flag, not LACT.
- **Instability appears under load, not at idle.** Always burn before calling a
  profile done.
- **A driver reset needs a cold power cycle** on this platform. Do not stack
  aggressive changes; one at a time.
- **Repaste is still recommended.** If the junction is high at a low power cap,
  the paste or the mounting is the problem; software cannot fix that.

## Revert to stock

Remove the GPU entry from `/etc/lact/config.yaml` (or set the fields back to
their defaults), then:

```sh
systemctl restart lactd
```

The driver returns to its default power limit and clocks. Re-run the burn to
confirm the stock behaviour if you are debugging.

## Safety

- Do not exceed the driver's allowed ranges; `lact cli power-limit get` prints
  the min/max.
- Keep the junction below 90 °C under sustained load, with margin for a hot
  room.
- Stop the load if you see artefacts, a reset, or the fans at maximum with
  clocks at minimum.
- Never leave a burn running unattended on a card with a known cooling
  problem.
