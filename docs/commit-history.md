# Commit History — Full Technical Breakdown

All commits are listed **oldest to newest** (the order work was actually done).

---

## 1. `60fc976` — Uploaded Android_boot_image_editor

**Date**: 2026-04-20 09:56 IST  
**Author**: ravindu644

### What happened

The base toolchain for the entire project was added. This is a verbatim copy of [cfig/Android_boot_image_editor](https://github.com/cfig/Android_boot_image_editor) — a Kotlin/Gradle tool that can unpack and repack Android boot, recovery, vendor_boot, vbmeta, dtbo, and sparse image files.

### Files added

| File | Purpose |
|------|---------|
| `.gitattributes` | Marks `aosp/`, `external/`, `avb/` as vendored so GitHub's language statistics ignore them |
| `.gitignore` | Ignores `.idea`, `.gradle`, `build/`, `__pycache__` |
| `.gitmodules` | Registers three integration-test resource submodules |
| `.travis.yml` | CI configuration (Linux + macOS, Gradle check + integrationTest.py) |
| `LICENSE.md` | Apache 2.0 license |
| `README.md` | Full usage documentation for the boot image editor tool |
| `gradlew` / `gradlew.bat` | Gradle wrapper scripts |
| `aosp/` | AOSP-sourced tools: `avbtool`, `mkbootimg`, signing keys, ext4/f2fs utilities, `mkdtboimg`, `extract_kernel.py`, `libxbc`, `dispol`, `dracut` |
| `bbootimg/bbootimg.jar` | Pre-built JAR for the boot image editor |
| `src/resources/console.rc` | Recovery console init script (part of the editor's test fixtures) |
| `src/resources/init.debug.rc` | Debug init script (part of the editor's test fixtures) |
| `src/test/resources/boot.img` | Sample boot image for integration tests |
| `tools/` | Helper scripts: `abe`, port/release makefiles, `pull.py`, `factory_image_parser.py`, `free.py`, `syncCode.sh`, binary diffs, `debug.kts` |

### Key capabilities this enables

- `./gradlew unpack` — unpack any Android image into `build/unzip_boot/`
- `./gradlew pack` — repack and re-sign back into a flashable image
- `./gradlew clear` — clean workspace
- `./gradlew pull` — pull DTB from a rooted device via ADB

---

## 2. `928f899` — Uploaded stock recovery.img

**Date**: 2026-04-20 09:57 IST  
**Author**: ravindu644

### What happened

The original Samsung recovery image was committed to the repository root as `recovery.img` (80 MiB binary). This serves as the starting point for all subsequent modifications.

### Files added

| File | Notes |
|------|-------|
| `recovery.img` | Stock Samsung recovery image, 80 MiB, mode 0755 |

---

## 3. `c0d6760` — Unpacked stock recovery.img

**Date**: 2026-04-20 10:46 IST  
**Author**: ravindu644

### What happened

`./gradlew unpack` was run on the stock `recovery.img`. The tool extracted every component of the boot image into `build/unzip_boot/`. This commit captures the entire unpacked state so that subsequent diffs represent only the intentional modifications.

### Extracted components

| Path | Description |
|------|-------------|
| `build/unzip_boot/kernel` | Stock compressed kernel image (ARM64) |
| `build/unzip_boot/dtb` | Device-tree blob |
| `build/unzip_boot/kernel_version.txt` | Contains `5.15.148` |
| `build/unzip_boot/kernel_configs.txt` | Full kernel `.config` (8249 lines) extracted from the kernel image's embedded config section. Compiled with Android LLVM/Clang 14.0.7. |
| `build/unzip_boot/recovery.json` | Boot image header metadata (offsets, sizes, compression, header version) |
| `build/unzip_boot/recovery.avb.json` | AVB footer metadata (hash algorithm, digest, salt, flags) |
| `build/unzip_boot/role` | Image role identifier |
| `build/unzip_boot/ramdisk.img.lz4` | Original compressed ramdisk |
| `build/unzip_boot/root/` | Full ramdisk extracted here — all `system/`, `vendor/`, `lib/modules/`, `.rc` files, SELinux policy binaries, property contexts, etc. |

### Notable kernel configuration facts (from `kernel_configs.txt`)

- Kernel version: **Linux 5.15.148 ARM64**
- Compiler: Android Clang 14.0.7 (LLVM LLD linker)
- `CONFIG_MODULES=y` — loadable kernel modules supported
- `CONFIG_OVERLAY_FS=y` — required for container filesystems
- `CONFIG_NAMESPACES=y`, `CONFIG_USER_NS=y` — Linux namespace isolation
- `CONFIG_CGROUPS=y` — cgroup v1 and v2 support
- `CONFIG_BINDER_IPC=y` — Android binder IPC
- `CONFIG_DM_VERITY=y` — dm-verity (verified boot)
- Multiple MediaTek-specific drivers built-in

### Stock ramdisk contents (representative)

The `root/` directory contains:
- `/system/bin/`: `adbd`, `recovery`, `fastbootd`, `sh`, `toybox`, `toolbox`, `init`, `linker64`, filesystem tools (`e2fsck`, `mke2fs`, `fsck.f2fs`, `make_f2fs`, `mkfs.erofs`, etc.)
- `/system/lib64/`: Full set of Android system shared libraries
- `/system/etc/init/hw/init.rc`: Primary init script
- `/lib/modules/`: ~100 MediaTek kernel modules (clocks, power management, display, UFS, USB, etc.)
- `/vendor/firmware/`: FM radio firmware, NFC firmware, speaker calibration data
- Hundreds of SELinux policy files (`sepolicy`, `*_file_contexts`, `*_property_contexts`, `*_service_contexts`)

---

## 4. `872a174` — Enable ADB root and start adbd on post-fs-data

**Date**: 2026-04-20 10:50 IST  
**Author**: ravindu644

### What happened

Three changes were made to give a root ADB shell immediately after the recovery boots:

#### `prop.default` changes

| Property | Before | After |
|----------|--------|-------|
| `ro.secure` | `1` | `0` |
| `ro.adb.secure` | `1` | `0` |
| `ro.debuggable` | `0` | `1` |
| `service.adb.root` | _(unset)_ | `1` |
| `ro.force.debuggable` | _(unset)_ | `1` |

Setting `ro.secure=0` and `ro.adb.secure=0` bypasses ADB authentication. `ro.debuggable=1` enables debug builds. `service.adb.root=1` makes `adbd` start as root.

#### `plat_property_contexts` change

Added a context entry so `ro.force.debuggable` is recognized as a valid property:
```
ro.force.debuggable u:object_r:build_prop:s0 exact bool
```

#### `init.rc` change — trigger adbd on post-fs-data

Added at end of `init.rc`:
```
on post-fs-data
    setprop sys.usb.config adb
```

Setting `sys.usb.config=adb` triggers the existing `on property:sys.usb.config=adb` handler, which starts `adbd`. This runs at the `post-fs-data` stage, which is after filesystems are mounted but before the device becomes fully initialized — ensuring ADB is available very early.

---

## 5. `ca02f70` — Patch sepolicy to allow ADB root and set recovery permissive

**Date**: 2026-04-20 10:53 IST  
**Author**: ravindu644

### What happened

The precompiled SELinux policy binary (`build/unzip_boot/root/sepolicy`) was patched using **magiskpolicy** to allow `adbd` to transition into the `su` SELinux domain and to mark key domains as permissive.

### Exact magiskpolicy command

```bash
./magiskpolicy --load sepolicy --save sepolicy.patched '
allow adbd adbd process setcurrent
allow adbd su process dyntransition
permissive { adbd }
permissive { su }
permissive { recovery }
'
```

### What each rule does

| Rule | Effect |
|------|--------|
| `allow adbd adbd process setcurrent` | Allows the `adbd` process to change its own SELinux context |
| `allow adbd su process dyntransition` | Allows `adbd` to dynamically transition into the `su` domain (root shell) |
| `permissive { adbd }` | `adbd` domain violations are logged but not denied |
| `permissive { su }` | `su` domain violations are logged but not denied |
| `permissive { recovery }` | The `recovery` domain (used by all custom init services) is permissive — denials are logged but do not block execution |

The patched binary replaces the original `build/unzip_boot/root/sepolicy` blob directly.

---

## 6. `5c06cdd` — Inject selinux-permissive script and service

**Date**: 2026-04-20 11:21 IST  
**Author**: ravindu644

### What happened

An additional runtime SELinux enforcement disabler was added on top of the sepolicy patch. Even if the policy patch does not fully suppress denials, this script writes `0` to `/sys/fs/selinux/enforce` at init time, putting the kernel SELinux subsystem into fully permissive (audit-only) mode.

### New script: `/system/bin/selinux-permissive`

```sh
#!/system/bin/sh
echo 0 > /sys/fs/selinux/enforce
```

### `init.rc` changes

A new service definition was added:
```
service selinux-permissive /system/bin/selinux-permissive
    disabled
    oneshot
    user root
    group root
    seclabel u:r:recovery:s0
```

And it is started at the `on init` trigger, before filesystem mounts and hardware initialization:
```
on init
    start selinux-permissive
```

The `on init` trigger fires before the filesystem mount stages and hardware initialization (`early-fs`, `fs`, `post-fs`, `post-fs-data`, `early-boot`, `boot`). Running `selinux-permissive` here ensures SELinux is in permissive mode before any hardware services or driver initialization begins.

---

## 7. `df2296c` — Updated .gitignore

**Date**: 2026-04-20 11:23 IST  
**Author**: ravindu644

### What happened

Build artifacts that should not be tracked in git were added to `.gitignore`:

```
build/unzip_boot/ramdisk.img
build/unzip_boot/ramdisk.img.lz4
recovery.img.clear
recovery.img.google
recovery.img.signed
uiderrors
```

`recovery.img.signed` is the output of `./gradlew pack`. `ramdisk.img` and `ramdisk.img.lz4` are regenerated on each pack. `recovery.img.clear` and `recovery.img.google` are intermediate files created by the AVB signing toolchain.

---

## 8. `b9315a2` — Remove dsms service (Samsung diagnostic telemetry)

**Date**: 2026-04-20 11:30 IST  
**Author**: ravindu644

### What happened

Samsung ships a proprietary diagnostic/telemetry daemon called **dsms** (Device Security Management Service or similar). Its binary, init scripts, and all references were removed.

### Files deleted

| File | Contents |
|------|----------|
| `build/unzip_boot/root/system/bin/dsms` | Binary (proprietary Samsung daemon, ~unknown purpose) |
| `build/unzip_boot/root/system/etc/init/dsms.rc` | Sets up `/efs/dsms/` and `/data/local/dsms/` directories, log files, restorecon |
| `build/unzip_boot/root/system/etc/init/dsms_common.rc` | Defines `dsmsd` service (class core, user/group vendor_dsms) and starts it on boot |

### `init.rc` cleanup

The inline `dsmsd` service definition that had been added directly to `init.rc` was also removed:
```
# Removed:
on boot
    start dsmsd

service dsmsd /system/bin/dsms
    disabled
    user 5031
    group 5031
    seclabel u:r:dsms:s0
```

---

## 9. `c1f32bf` — Mark `recovery` service as disabled

**Date**: 2026-04-20 11:44 IST  
**Author**: ravindu644

### What happened

The stock `recovery` service definition in `init.rc` was modified to add the `disabled` flag:

```diff
 service recovery /system/bin/recovery
     socket recovery stream 422 system system
     seclabel u:r:recovery:s0
+    disabled
```

### Why this matters

Without `disabled`, Android's init would automatically start the `recovery` binary, which would launch the Samsung recovery menu UI, occupying the display and handling input. By disabling it, the recovery binary never runs automatically, leaving the display and input free for the custom `recovery-console` service (added in the next commit). The `recovery` binary can still be started manually if needed.

---

## 10. `6692a91` — Add and start recovery-console service on boot

**Date**: 2026-04-20 12:17 IST  
**Author**: ravindu644

### What happened

The `recovery-console` binary was added and wired into the init system to start on every boot.

### New binary: `/system/bin/recovery-console`

A pre-built ARM64 binary. Its role is to act as a **display server and output multiplexer** for the recovery environment. It can render text/graphics to the device display, and it has an `--exec` mode that wraps another command's stdout/stderr and displays it. This is the component that allows the Ubuntu container's console output to appear on the device screen.

### `init.rc` changes

```
service recovery-console /system/bin/recovery-console
    disabled
    oneshot
    user root
    group root
    seclabel u:r:recovery:s0

on boot
    start recovery-console
```

Note: This service definition was later replaced/reworked in commit `45e7861` (the droidspaces daemon commit), where the `on boot` trigger and the bare `recovery-console` start were commented out, and instead `recovery-console` is launched as a wrapper around `droidspaces` via `boot-ubuntu.sh`.

---

## 11. `96dbf77` — Centralize USB ConfigFS logic to a single file

**Date**: 2026-04-20 12:33 IST  
**Author**: ravindu644

### What happened

All the USB gadget (ADB and fastboot over USB) initialization logic was extracted from the monolithic `init.rc` into a dedicated file: `init.recovery.usb.rc`.

### Why

This is a clean code organization change. The main `init.rc` was getting large. Moving USB gadget logic to its own file makes each file's responsibility clear:
- `init.rc` — core system bootstrap
- `init.recovery.usb.rc` — all USB ADB/fastboot gadget setup

### New file: `build/unzip_boot/root/system/etc/init/init.recovery.usb.rc`

Contains 105 lines covering:

**Services defined:**
- `adbd` — ADB daemon (`--root_seclabel=u:r:su:s0`, socket `adbd stream 660 system system`)
- `fastbootd` — Fastboot daemon

**Property triggers:**
- `on property:service.adb.root=1` → restart adbd (for dynamic root elevation)

**ConfigFS gadget setup (when `sys.usb.configfs=1`):**
- Mounts configfs at `/config`
- Creates USB gadget `g1` with vendor ID `0x18D1` (Google)
- Sets serial number, manufacturer, product strings from system properties
- Creates function directories: `ffs.adb`, `ffs.fastboot`, `ss_mon.etc`
- Creates config `b.1` with MaxPower 900mA

**Legacy android_usb setup (when `sys.usb.configfs=0`):**
- Sets aliases, vendor ID, manufacturer, product, serial via `/sys/class/android_usb/android0/`

**Function filesystem mounts:**
- `/dev/usb-ffs/adb` (functionfs, uid=2000/gid=2000)
- `/dev/usb-ffs/fastboot` (functionfs, rmode=0770, fmode=0660, uid=1000/gid=1000)

**USB config property triggers:**
- `sys.usb.config=adb` → start adbd
- `sys.usb.config=fastboot` → start fastbootd
- `sys.usb.config=none` → stop both, clear gadget
- `sys.usb.config=sideload` → ADB with `0xD001` product ID
- ConfigFS variants: symlink functions into config, set UDC controller

**USB product IDs:**
| Mode | Product ID |
|------|-----------|
| ADB / sideload | `0xD001` |
| Fastboot | `0x4EE0` |

---

## 12. `8a63a39` — Replace kernel with custom Droidspaces-compatible kernel

**Date**: 2026-04-20 12:52 IST  
**Author**: ravindu644

### What happened

The stock Samsung kernel image at `build/unzip_boot/kernel` was replaced with a custom-compiled kernel binary.

### Why

The commit message states the custom kernel adds "Droidspaces support," but the exact changes relative to the stock kernel are not visible in the repo — only the binary was committed, not the source diff.

Notable observations:
- The custom kernel binary is **smaller** than the stock: 17.4 MiB vs 20.4 MiB. This suggests the custom build may have stripped debug symbols, unused drivers, or other components.
- The `kernel_configs.txt` in the repo was extracted from the **stock** kernel during the initial unpack (commit `c0d6760`) and was not updated by this commit. It shows the stock recovery kernel already had `CONFIG_NAMESPACES=y`, `CONFIG_CGROUPS=y`, `CONFIG_OVERLAY_FS=y`, and all other required options enabled.
- Without comparing the two kernel binaries directly (e.g., by extracting configs from both), it is not possible to determine what specifically changed.
- `droidspaces` v5.9.5 uses only standard Linux syscalls (`clone`, `unshare`, `setns`, `pivot_root`, `mount`) with no SoC-specific kernel interfaces, so it is unlikely to require custom kernel patches beyond standard config options.

The base version (5.15.148) and target hardware (MT6835) are unchanged. Only the kernel binary was replaced.

---

## 13. `db503c2` — Add shell environment config and PS1 prompt

**Date**: 2026-04-20 13:07 IST  
**Author**: ravindu644

### What happened

ADB shell sessions now show a proper shell prompt instead of a blank `$` or `#`.

### New file: `/system/etc/environment`

```sh
#!/system/bin/sh
export PS1='$(whoami)@$(hostname):$PWD # '
```

This produces a prompt like:
```
root@localhost:/ #
```

### `init.rc` change

The `ENV` environment variable was exported so BusyBox/toybox `sh` picks up the environment file:

```diff
 on init
     export ANDROID_ROOT /system
     export ANDROID_DATA /data
     export EXTERNAL_STORAGE /sdcard
+    export ENV /system/etc/environment
```

POSIX `sh` (and BusyBox ash) reads the file pointed to by `$ENV` on startup when running interactively, similar to how bash reads `.bashrc`. Setting this globally in the init environment means every shell process spawned on the device inherits `$ENV` and gets the custom prompt.

---

## 14. `209e6e0` — Wire up MTK gen4m WLAN driver inside the recovery

**Date**: 2026-04-20 14:07 IST  
**Author**: ravindu644

### What happened

Wi-Fi support was added to the recovery environment. The MediaTek MT6835 uses a combo chip (MT6631) for Wi-Fi and Bluetooth. The driver is the gen4m series (`wlan_drv_gen4m_6835.ko`), loaded via modprobe, with the WMT (Wireless Management Technology) co-existence daemon managing the chip.

### New files added

#### `/system/bin/wlan_init.sh`

Shell script that brings up `wlan0`. Steps:
1. Redirects all output to `/tmp/wlan-logs.txt`
2. Runs `/vendor/bin/wmt_loader` (loads firmware patch)
3. Runs `/vendor/bin/wmt_launcher -p /vendor/firmware/ -o 1 &` (starts WMT daemon in background)
4. Polls `vendor.connsys.driver.ready` property for up to 10 seconds (20 × 0.5s)
5. Writes `1` to `/dev/wmtWifi` to power on the Wi-Fi subsystem
6. Checks for `wlan0` with `ifconfig -a` and brings it up with `ifconfig wlan0 up`
7. On failure, dumps last 20 lines of `dmesg | grep -iE "WMT|wlan|WIFI"` and exits 1

#### `/system/etc/init/init.mtk.wlan.rc`

Init script with the following structure:

```
on early-boot
    setprop vendor.connsys.driver.ready no

on boot
    mkdir /nvdata 0771 system system
    mount ext4 /dev/block/sdc28 /nvdata wait noatime
    write /sys/module/firmware_class/parameters/path /vendor/firmware,/nvdata/APCFG/APRDEB,/efs/wifi
    start load_wlan_driver

service load_wlan_driver /system/bin/modprobe -d /vendor/wlan_modules/lib/modules/ wlan_drv_gen4m_6835.ko nvram=WIFI
    user root; group root; oneshot; disabled; seclabel u:r:recovery:s0

service wifi-helper /system/bin/sh /system/bin/wlan_init.sh
    user root; group root; oneshot; disabled; seclabel u:r:recovery:s0

on property:init.svc.load_wlan_driver=stopped
    start wifi-helper
```

The sequence is: `boot` → `load_wlan_driver` (modprobe) → on stopped → `wifi-helper` (wlan_init.sh).

The nvdata partition (`/dev/block/sdc28`) is mounted because the Wi-Fi driver reads NVRAM calibration data from `/nvdata/APCFG/APRDEB`.

#### Vendor binaries

| File | Purpose |
|------|---------|
| `/vendor/bin/wmt_loader` | Loads WMT firmware patch into the combo chip |
| `/vendor/bin/wmt_launcher` | WMT daemon — manages Bluetooth/Wi-Fi co-existence |

#### Vendor firmware files

| File | Purpose |
|------|---------|
| `connsys_mt6835_mt6631.bin` | MT6835/MT6631 combo chip firmware |
| `WMT_SOC.cfg` | WMT co-existence configuration (antenna mode, GPS LNA, clock, TSSI) |
| `BT_FW.cfg` | Bluetooth firmware config (TX power limits, co-existence settings) |
| `fm_cust.cfg` | FM radio custom config (RSSI thresholds, de-emphasis, oscillator freq) |
| `wifi.cfg` | Wi-Fi calibration data |
| `aw883xx_acf.bin` | Speaker amplifier firmware (Awinic AW883xx) |
| `focaltech_ft3419_mp_sx.ini` | FocalTech touchscreen manufacturing test parameters |
| `grippower.info` | Grip sensor calibration |
| Various `mt66xx_fm_*.bin` | FM radio coefficients and patch files for multiple chip revisions |
| `remoteproc_scp` | SCP (Sensor Control Processor) firmware |
| `sipa.bin` | SIPA (Smart Intelligent Power Amplifier) — audio amplifier PA firmware |
| `zt7650m_a16.bin` | Zinitix ZT7650M touchscreen firmware (alternative touch controller) |
| `nfc/sec_s3nrn4v_firmware.bin` | NFC controller firmware |

#### WLAN kernel module stack (`/vendor/wlan_modules/lib/modules/`)

| Module | Purpose |
|--------|---------|
| `wlan_drv_gen4m_6835.ko` | Main Wi-Fi driver (MTK gen4m, MT6835-specific) |
| `wmt_drv.ko` | WMT core driver |
| `wmt_chrdev_wifi.ko` | WMT character device for Wi-Fi control |
| `connadp.ko` | Connectivity adaptation layer |
| `bt_drv_connac1x.ko` | Bluetooth driver (ConnAC1x platform) |
| `btif_drv.ko` | Bluetooth HCI interface driver |
| `ccci_md_all.ko` | CCCI modem driver (cellular interface) |
| `ccci_util_lib.ko` | CCCI utility library |
| `ccci_auxadc.ko` | CCCI auxiliary ADC |
| `ccmni.ko` | CCCI modem network interface |
| `mddp.ko` | MediaTek data path acceleration |
| `rps_perf.ko` | RPS (Receive Packet Steering) performance module |
| MTK power management (`mtk_pbm.ko`, `mtk_mdpm.ko`, etc.) | Various power management modules needed by the Wi-Fi stack |

---

## 15. `0458f9b` — Wire up FocalTech touch drivers

**Date**: 2026-04-20 14:23 IST  
**Author**: ravindu644

### What happened

Touchscreen support was added for the FocalTech FT3419U controller. After this commit, `/dev/input/event8` appeared and the touchscreen was fully functional.

### Verified working (from commit message dmesg output)

```
[  3.924097] init: starting service 'focaltech-tp'...
[  4.163925] init: Service 'focaltech-tp' (pid 293) exited with status 0
[  4.164023] init: Sending signal 9 to service 'focaltech-tp' (pid 293)...
```

`lsmod` confirmed `focaltech_tp` (237568 bytes), `tuihw_inf` (20480), and `sec_cmd` (24576) were loaded.

### New file: `/system/etc/init/init.touch.rc`

```
service focaltech-tp /system/bin/modprobe -d /vendor/lib/modules --all=/vendor/lib/modules/modules.load
    user root; group root; oneshot; disabled; seclabel u:r:recovery:s0

on boot
    write /sys/module/firmware_class/parameters/path /vendor/firmware,/nvdata/APCFG/APRDEB,/efs/wifi
    start focaltech-tp
```

The `--all` flag to modprobe loads all modules listed in `modules.load` in dependency order.

### New kernel modules (`/vendor/lib/modules/`)

| Module | Size | Purpose |
|--------|------|---------|
| `focaltech_tp.ko` | ~237 KiB | Main FocalTech touchscreen driver (FT3419U) |
| `tuihw-inf.ko` | ~20 KiB | TUI (Trusted UI) hardware interface — required by focaltech_tp |
| `sec_cmd.ko` | ~24 KiB | Samsung command interface — required by focaltech_tp |

### Module dependency map (`modules.dep`)

```
tuihw-inf.ko:
focaltech_tp.ko: tuihw-inf.ko sec_cmd.ko
sec_cmd.ko:
```

Load order (from `modules.load`):
1. `sec_cmd.ko`
2. `tuihw-inf.ko`
3. `focaltech_tp.ko`

### Module metadata files

All standard kernel module index files were created:
- `modules.alias` — device tree aliases (`of:N*T*Cfocaltech,fts` and `of:N*T*Cfocaltech,ftsC*`)
- `modules.alias.bin` — binary version
- `modules.builtin` — list of 675 in-tree kernel built-in modules (full Linux + Android stack)
- `modules.builtin.bin`, `modules.builtin.alias.bin`, `modules.builtin.modinfo` — binary indexes
- `modules.dep`, `modules.dep.bin` — dependency graph
- `modules.devname` — device node names (empty)
- `modules.order`, `modules.softdep` — load order and soft dependencies
- `modules.symbols`, `modules.symbols.bin` — exported symbol → module mapping

The `modules.symbols` file exports 20 symbols including:
- `stui_*` — TUI session management (from `tuihw_inf` and `focaltech_tp`)
- `sec_cmd_*` — Samsung command interface (from `sec_cmd`)

### Firmware files (already present from WLAN commit but used by touch)

- `focaltech_ts_fw_ft3419u.bin` — FocalTech FT3419U firmware binary
- `focaltech_ft3419_mp_sx.ini` — Manufacturing test parameters (423-line INI file specifying interface type FT3519T, 1080×2340 resolution, I2C slave address 0x70, etc.)

---

## 16. `45e7861` — Add droidspaces daemon and Ubuntu container services

**Date**: 2026-04-20 15:37 IST  
**Author**: ravindu644

### What happened

This is the culminating commit. The Droidspaces container runtime daemon and all the services needed to launch an Ubuntu 24.04 container were added.

### New binary: `/system/bin/droidspaces`

A pre-built ARM64 binary (~323 KiB). This is the Droidspaces container runtime. It has at least two modes:
- `droidspaces daemon --foreground` — runs the daemon that manages the container runtime socket
- `droidspaces -i <rootfs> -n <name> -h <hostname> <flags> start` — launches a container from an image file or block device

**Flags used in `boot-ubuntu.sh`:**

| Flag | Meaning |
|------|---------|
| `--hw-access` | Grant the container direct hardware access |
| `--privileged=full` | Full privilege mode (all capabilities) |
| `-B /tmp:/recovery` | Bind-mount host `/tmp` into container at `/recovery` |
| `--foreground` | Run in foreground (don't daemonize) |
| `-i <path>` | Image-backed rootfs (`.img` file or block device) |
| `-r <path>` | Directory-backed rootfs (alternative to `-i`) |
| `-n <name>` | Container display name |
| `-h <hostname>` | Container hostname |

### New file: `/system/bin/boot-ubuntu.sh`

```sh
#!/system/bin/sh

DROIDSPACES_BINARY_PATH=/system/bin/droidspaces
RECOVERY_CONSOLE_PATH=/system/bin/recovery-console

CONTAINER_NAME="Ubuntu 24.04"
CONTAINER_HOSTNAME=ubuntu
DS_FLAGS="--hw-access --privileged=full -B /tmp:/recovery --foreground"

# Rootfs path. Accepts only .img files or raw
# block devices like /dev/block/* (SD cards, partitions).
# If you want to use a directory-based rootfs, simply change
# -i ${ROOTFS_PATH} to -r ${ROOTFS_PATH} in the main command.
ROOTFS_PATH=/dev/block/mmcblk0p1

exec ${RECOVERY_CONSOLE_PATH} \
    --exec "${DROIDSPACES_BINARY_PATH} -i ${ROOTFS_PATH} -n \"${CONTAINER_NAME}\" -h \"${CONTAINER_HOSTNAME}\" ${DS_FLAGS} start"
```

The rootfs is expected at `/dev/block/mmcblk0p1` — the first partition of the `mmcblk0` block device (which may be internal storage, an SD card, or another MMC device depending on the device's partition layout). Any `.img` file path or block device path can be substituted by editing `ROOTFS_PATH` in the script.

`recovery-console --exec "..."` wraps the droidspaces process, connecting its output to the device display.

### New file: `/system/etc/init/init.ubuntu-droidspaces.example.rc`

```
service droidspacesd /system/bin/droidspaces daemon --foreground
    user root; group root; disabled; seclabel u:r:recovery:s0

service ubuntu-droidspaces /system/bin/sh /system/bin/boot-ubuntu.sh
    user root; group root; oneshot; disabled; seclabel u:r:recovery:s0

on boot
    start droidspacesd

on property:init.svc.droidspacesd=running
    start ubuntu-droidspaces
```

This creates a proper sequenced startup:
1. On boot → start `droidspacesd` (the daemon)
2. When `droidspacesd` is confirmed running → start `ubuntu-droidspaces` (launch container)

The property trigger `init.svc.droidspacesd=running` is set by Android init when a service transitions to the running state, ensuring the container is only launched after the runtime socket is ready.

### `init.rc` changes

The previous unconditional `recovery-console` start (from commit `6692a91`) was commented out, because `recovery-console` is now launched as a child process of `boot-ubuntu.sh` rather than directly by init:

```diff
-service recovery-console /system/bin/recovery-console
-    disabled
-    oneshot
-    user root
-    group root
-    seclabel u:r:recovery:s0
-
-on boot
-    start recovery-console
+#service recovery-console /system/bin/recovery-console
+#    disabled
+#    oneshot
+#    user root
+#    group root
+#    seclabel u:r:recovery:s0
+
+#on boot
+#    start recovery-console
```

Users who want to enable the Ubuntu container boot should rename `init.ubuntu-droidspaces.example.rc` to `init.ubuntu-droidspaces.rc` (remove `.example`) and set their correct rootfs path in `boot-ubuntu.sh`.
