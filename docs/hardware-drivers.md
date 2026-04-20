# Hardware Drivers

This document covers the two optional hardware driver stacks added to the recovery: Wi-Fi and touchscreen. Both are marked as `[OPTIONAL]` in the commit history, meaning they are not required for the Droidspaces container to boot, but they significantly improve usability.

---

## Wi-Fi — MediaTek MT6835 gen4m (commit `209e6e0`)

### Hardware

- **SoC**: MediaTek MT6835
- **Combo chip**: MT6631 (handles Wi-Fi + Bluetooth + FM radio + GPS)
- **Wi-Fi standard**: IEEE 802.11 (gen4m driver family)
- **Interface**: `wlan0` after successful initialization

### Driver Stack

The Wi-Fi bring-up requires multiple components working in sequence:

```
Kernel module: wlan_drv_gen4m_6835.ko
  ↑ requires: wmt_drv.ko (WMT core), wmt_chrdev_wifi.ko (/dev/wmtWifi)
  ↑ requires: ccci_md_all.ko + friends (CCCI modem interface)
  ↑ requires: connadp.ko (connectivity adaptation)
  ↑ requires: mddp.ko (data path), rps_perf.ko (RX packet steering)
  ↑ requires: MTK power management modules
```

Userspace:
```
/vendor/bin/wmt_loader   → loads firmware patch into MT6631 chip hardware
/vendor/bin/wmt_launcher → WMT daemon: manages BT/Wi-Fi co-existence
```

### Init Sequence (`init.mtk.wlan.rc`)

1. `early-boot`: set `vendor.connsys.driver.ready=no`
2. `boot`:
   - Create `/nvdata` directory (mode 0771, system:system)
   - Mount `/dev/block/sdc28` as ext4 at `/nvdata` (noatime, wait for device)
   - Set firmware search path: `/vendor/firmware,/nvdata/APCFG/APRDEB,/efs/wifi`
   - Start `load_wlan_driver` service
3. `load_wlan_driver` runs: `modprobe -d /vendor/wlan_modules/lib/modules/ wlan_drv_gen4m_6835.ko nvram=WIFI`
4. When `load_wlan_driver` stops: start `wifi-helper` (runs `wlan_init.sh`)

### `wlan_init.sh` Script

```sh
exec > /tmp/wlan-logs.txt 2>&1      # log everything

# Step 1: Load firmware patch into chip
/vendor/bin/wmt_loader              # exits; firmware now in chip

# Step 2: Start WMT daemon (manages BT/WiFi co-existence)
/vendor/bin/wmt_launcher -p /vendor/firmware/ -o 1 &

# Step 3: Wait for connsys ready (up to 10 seconds)
for i in $(seq 1 20); do
    [ "$(getprop vendor.connsys.driver.ready)" = "yes" ] && break
    sleep 0.5
done

# Step 4: Power on Wi-Fi subsystem
echo 1 > /dev/wmtWifi

# Step 5: Bring up wlan0
if ifconfig -a | grep -q "wlan0"; then
    ifconfig wlan0 up
else
    dmesg | grep -iE "WMT|wlan|WIFI" | tail -20
    exit 1
fi
```

Logs are written to `/tmp/wlan-logs.txt`. Since `/tmp` is bind-mounted into the container at `/recovery`, the container can read these logs at `/recovery/wlan-logs.txt`.

### Wi-Fi Firmware Files

Located at `/vendor/firmware/`:

| File | Purpose |
|------|---------|
| `connsys_mt6835_mt6631.bin` | MT6835+MT6631 combo chip firmware blob |
| `WMT_SOC.cfg` | WMT co-existence config: antenna mode (1=shared), GPS LNA pin (0=disabled), co-clock flag (1=enabled), BT TSSI from WiFi (3), WiFi antenna swap mode |
| `BT_FW.cfg` | BT firmware config: co-existence settings, TX power limits (0–20 dBm in 2 dBm steps), vendor commands |
| `fm_cust.cfg` | FM radio: RSSI thresholds (-296), de-emphasis (50µs for mainland China), oscillator (26 MHz) |
| `wifi.cfg` | Wi-Fi calibration data |
| `mt6631_fm_v1_coeff.bin` / `mt6631_fm_v1_patch.bin` | FM radio coefficient and patch files for MT6631 |
| `mt6627_fm_*.bin`, `mt6630_fm_*.bin`, `mt6632_fm_*.bin`, `mt6635_fm_*.bin` | FM radio files for other MTK chip variants (shipped together for compatibility) |

### Module Stack (`/vendor/wlan_modules/lib/modules/`)

| Module | Purpose |
|--------|---------|
| `wlan_drv_gen4m_6835.ko` | Main Wi-Fi driver, MT6835-specific gen4m variant |
| `wmt_drv.ko` | WMT (Wireless Management Technology) core driver |
| `wmt_chrdev_wifi.ko` | Creates `/dev/wmtWifi` character device; writing `1` powers on Wi-Fi |
| `connadp.ko` | Connectivity adaptation layer between Wi-Fi and modem stack |
| `bt_drv_connac1x.ko` | Bluetooth driver for ConnAC1x platform (MTK BT HCI) |
| `btif_drv.ko` | Bluetooth HCI interface driver |
| `ccci_md_all.ko` | CCCI (Cross Core Communication Interface) modem driver |
| `ccci_util_lib.ko` | CCCI utility functions |
| `ccci_auxadc.ko` | CCCI auxiliary ADC (modem power measurement) |
| `ccmni.ko` | CCCI modem network interface (cellular data) |
| `mddp.ko` | MediaTek data path acceleration (offloads packet processing) |
| `rps_perf.ko` | Receive Packet Steering performance tuning |
| `mtk_low_battery_throttling.ko` | Throttles Wi-Fi TX on low battery |
| `mtk_dynamic_loading_throttling.ko` | Dynamic throughput throttling |
| `mtk-mbox.ko` | MTK mailbox driver (IPC between cores) |
| `mtk_mdpm.ko` | MTK modem power management |
| `mtk_pbm.ko` | MTK power budget manager |
| `mtk_rpmsg_mbox.ko` | RPMSG mailbox for inter-processor communication |
| `mtk_tinysys_ipi.ko` | TinySys IPI (Inter-Processor Interrupt) |

### NVRAM Calibration

The Wi-Fi driver is loaded with `nvram=WIFI`, which instructs it to read NVRAM calibration data. The `/nvdata` partition (`/dev/block/sdc28`) must be mounted before the module loads. The calibration file is expected at `/nvdata/APCFG/APRDEB/WIFI`.

Without calibration data, Wi-Fi may work but with incorrect TX power levels or poor sensitivity. The NVRAM partition is per-device and written at the factory.

---

## Touchscreen — FocalTech FT3419U (commit `0458f9b`)

### Hardware

- **Controller**: FocalTech FT3419U (IC type: FT3519T per the test config)
- **Interface**: I2C, slave address 0x70
- **Resolution**: 1080 × 2340 pixels, 5-point multitouch
- **Firmware**: `focaltech_ts_fw_ft3419u.bin`
- **After loading**: Creates `/dev/input/event8`

### Driver Stack

```
focaltech_tp.ko
  ↑ depends on: tuihw-inf.ko (TUI hardware interface)
  ↑ depends on: sec_cmd.ko (Samsung command interface)
  ↑ depends on: i2c-mt65xx.ko (built into system modules)
  ↑ depends on: mtk_panel_ext.ko, hardware_info.ko, etc. (already loaded)
```

### Init Sequence (`init.touch.rc`)

```rc
service focaltech-tp /system/bin/modprobe -d /vendor/lib/modules \
        --all=/vendor/lib/modules/modules.load
    user root; group root; oneshot; disabled; seclabel u:r:recovery:s0

on boot
    write /sys/module/firmware_class/parameters/path \
          /vendor/firmware,/nvdata/APCFG/APRDEB,/efs/wifi
    start focaltech-tp
```

**Timing**: Runs at `boot` trigger, same as Wi-Fi init. Both happen in parallel.

**`--all` flag**: Tells modprobe to load all modules listed in `modules.load` in order, resolving dependencies. The load order is:
1. `sec_cmd.ko`
2. `tuihw-inf.ko`
3. `focaltech_tp.ko`

**Firmware path**: The same path written for Wi-Fi is also used by the touch driver to find `focaltech_ts_fw_ft3419u.bin`.

### Verified Output (from commit message)

After loading, the kernel logs show:
```
[  3.924097] init: starting service 'focaltech-tp'...
[  4.163925] init: Service 'focaltech-tp' (pid 293) exited with status 0 oneshot service took 0.237000 seconds in background
[  4.164023] init: Sending signal 9 to service 'focaltech-tp' (pid 293) process group...
```

The entire driver stack loads in ~0.24 seconds. After loading:
```
/dev/input/
  event0 ... event7   (existing devices: power key, volume keys, etc.)
  event8              (FocalTech FT3419U touchscreen — NEW)
  mice
```

`lsmod` output confirms the module is loaded with all expected dependents.

### Module Files (`/vendor/lib/modules/`)

| File | Size | Type |
|------|------|------|
| `focaltech_tp.ko` | ~237 KiB | FocalTech FT3419U main driver |
| `tuihw-inf.ko` | ~20 KiB | Trusted UI hardware interface |
| `sec_cmd.ko` | ~24 KiB | Samsung command interface |
| `modules.alias` | Text | OF aliases: `of:N*T*Cfocaltech,fts` and `of:N*T*Cfocaltech,ftsC*` |
| `modules.alias.bin` | Binary | Binary version of aliases |
| `modules.builtin` | 675 lines | List of all built-in kernel modules |
| `modules.builtin.bin` | Binary | Binary index of built-ins |
| `modules.builtin.alias.bin` | Binary | Alias index for built-ins |
| `modules.builtin.modinfo` | Binary | Built-in module info |
| `modules.dep` | 3 lines | Dependency graph |
| `modules.dep.bin` | Binary | Binary dependency graph |
| `modules.devname` | Empty | No character devices |
| `modules.load` | 3 lines | Load order: sec_cmd, tuihw-inf, focaltech_tp |
| `modules.order` | 3 lines | Same as modules.load |
| `modules.softdep` | 1 line | Soft dependencies header (empty) |
| `modules.symbols` | 20 lines | Symbol → module mapping |
| `modules.symbols.bin` | Binary | Binary version of symbols |

### Exported Symbols

The `modules.symbols` file maps 20 symbols across the three modules:

**From `tuihw_inf`** (TUI hardware interface):
- `stui_clear_mask`, `stui_set_mask`
- `stui_get_tui_version`, `stui_set_tui_version`
- `stui_get_mode`, `stui_set_mode`
- `stui_get_touch_type`, `stui_set_touch_type`
- `stui_cancel_session`

**From `focaltech_tp`** (touchscreen driver):
- `stui_tsp_enter`, `stui_tsp_exit`, `stui_tsp_type`
- `sec_ex_mode_switch`

**From `sec_cmd`** (Samsung command interface):
- `sec_cmd_init`, `sec_cmd_exit`
- `sec_cmd_set_default_result`, `sec_cmd_set_cmd_result`, `sec_cmd_set_cmd_result_all`
- `sec_cmd_set_cmd_exit`

The `stui_*` symbols relate to Samsung's Trusted UI (TUI) framework, which allows TrustZone (TEE) applications to take over the display and touchscreen for secure input. In the recovery context, this is likely not used — the modules just need to be present for the driver to load without symbol resolution errors.

### Firmware Files

| File | Purpose |
|------|---------|
| `focaltech_ts_fw_ft3419u.bin` | FocalTech FT3419U touchscreen firmware |
| `focaltech_ft3419_mp_sx.ini` | Manufacturing production test parameters (423 lines) — used during factory QA, not at runtime |

The `.ini` file specifies:
- IC type: FT3519T
- Interface: I2C, slave 0x70
- Resolution: 1080 × 2340
- Max touch points: 5
- Various electrical test parameters (Iovcc, Vdd, standby currents)

---

## Other Firmware Files (present but not driver-specific)

These firmware files were added with the Wi-Fi commit. They correspond to additional hardware present on this device (speaker amp, NFC, sensors). The drivers that request these files are in `/lib/modules/` and are loaded during system module initialization:

| File | Purpose |
|------|---------|
| `aw883xx_acf.bin` | Awinic AW883xx smart speaker amplifier calibration |
| `zt7650m_a16.bin` | Zinitix ZT7650M touchscreen firmware (alternative touch controller) |
| `nfc/sec_s3nrn4v_firmware.bin` | Samsung S3NRN4V NFC controller firmware |
| `remoteproc_scp` | SCP (Sensor Control Processor) firmware blob |
| `sipa.bin` | SIPA (Smart Intelligent Power Amplifier) — likely audio amplifier PA firmware |
| `grippower.info` | Grip sensor calibration data |

---

## Interaction with the Container

Both Wi-Fi and touch are initialized **before** the Ubuntu container starts:

```
boot trigger
  ├─ focaltech-tp (touch driver loads)     →  /dev/input/event8 ready
  ├─ load_wlan_driver (WLAN module loads)
  │    └─ wifi-helper (wlan0 up)           →  wlan0 ready
  └─ droidspacesd (starts)
       └─ ubuntu-droidspaces               →  container starts
            └─ Ubuntu 24.04 boots
                 ↑ can use /dev/input/event8 (touch) and wlan0 (Wi-Fi)
```

With `--hw-access` and `--privileged=full`, the Ubuntu container has direct access to both `/dev/input/event8` and the `wlan0` network interface, allowing full graphical and network functionality within the container.
