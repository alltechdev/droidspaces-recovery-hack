# Porting Checklist

Work through this checklist sequentially for any new device. Each section builds on the previous.

---

## Phase 0: Pre-qualification

Before writing a single line of code, answer these questions. A "no" at any mandatory item means the port is blocked.

- [ ] **Device has an unlocked bootloader** (or can be unlocked)
  - Samsung: OEM unlock enabled in developer options, not carrier-locked
  - Qualcomm: `fastboot flashing unlock` supported
  - MediaTek: `fastboot oem unlock` or SP Flash Tool DA unlock available
  - ❌ If no path to bootloader unlock exists, stop here

- [ ] **Device is ARM64** (`adb shell getprop ro.product.cpu.abi` returns `arm64-v8a`)
  - ❌ ARM32 (armeabi-v7a) devices cannot run `droidspaces` or `recovery-console`

- [ ] **Device runs Android 9.0+**
  - ❌ Android 8 and earlier use incompatible init system

- [ ] **Kernel is ≥ 4.14** (check `adb shell uname -r`)
  - ⚠️ 4.9 requires significant kernel patching — assess feasibility first
  - ⚠️ 4.14 works but requires `--block-nested-namespaces` flag

- [ ] **Recovery image can be extracted** (via OTA package, firmware dump, or official firmware)
  - Obtain the stock `recovery.img` (or `boot.img` for A/B devices, `vendor_boot.img` for GKI devices)
  - ❌ Without the stock image, the toolchain has nothing to unpack

---

## Phase 1: Stock Image Analysis

### 1.1 Determine partition layout

```bash
fastboot getvar all 2>&1 | grep -E "slot|recovery|dynamic|userspace"
```

Result options:
- `slot-count: 1` + `has-slot:recovery: yes` → Classic A-only → work with `recovery.img`
- `slot-count: 2` + `has-slot:recovery: no` → A/B → work with `boot.img`
- A/B + `dynamic-partition: true` + Android 13+ → VAB + init_boot → work with `vendor_boot.img`

- [ ] Identified partition layout type
- [ ] Obtained the correct stock image file

### 1.2 Unpack the stock image

```bash
cp /path/to/stock/recovery.img recovery.img   # or boot.img, vendor_boot.img
./gradlew unpack
```

- [ ] Unpack succeeds (no Gradle errors)
- [ ] `build/unzip_boot/root/` exists and contains `system/`, `lib/modules/`, etc.
- [ ] `build/unzip_boot/kernel_version.txt` populated
- [ ] `build/unzip_boot/kernel_configs.txt` populated (if `CONFIG_IKCONFIG=y` in the kernel)

### 1.3 Audit the stock kernel config

```bash
# If kernel_configs.txt is populated:
grep -E "^CONFIG_PID_NS|^CONFIG_IPC_NS|^CONFIG_NET_NS|^CONFIG_UTS_NS|\
^CONFIG_OVERLAY_FS|^CONFIG_CGROUPS|^CONFIG_CGROUP_NS|^CONFIG_USER_NS|\
^CONFIG_VETH|^CONFIG_DEVTMPFS|^CONFIG_LOOP" \
  build/unzip_boot/kernel_configs.txt
```

Record results:

| Config | Status |
|--------|--------|
| CONFIG_PID_NS | y / n / unknown |
| CONFIG_IPC_NS | y / n / unknown |
| CONFIG_NET_NS | y / n / unknown |
| CONFIG_UTS_NS | y / n / unknown |
| CONFIG_OVERLAY_FS | y / n / unknown |
| CONFIG_CGROUPS | y / n / unknown |
| CONFIG_USER_NS | y / n / unknown |
| CONFIG_DEVTMPFS | y / n / unknown |
| CONFIG_LOOP | y / n / unknown |
| CONFIG_VETH | y / n / unknown |

- [ ] Kernel config audited (or noted as unknown if kernel_configs.txt is empty)

### 1.4 Run droidspaces check on live device (optional but recommended)

Requires root access on the device while running normal Android (via Magisk, engineering mode, etc.):

```bash
adb push build/unzip_boot/root/system/bin/droidspaces /data/local/tmp/
adb shell chmod 755 /data/local/tmp/droidspaces
adb shell su -c /data/local/tmp/droidspaces check
```

- [ ] `droidspaces check` passes → no kernel rebuild needed
- [ ] OR `droidspaces check` lists specific failures → note missing features for Phase 2

---

## Phase 2: Kernel Decision

Based on Phase 1 results:

### If `droidspaces check` passed:

- [ ] **No kernel rebuild needed** — skip to Phase 3
- [ ] Copy the stock kernel to `build/unzip_boot/kernel` (it's already there from the unpack)

### If `droidspaces check` failed or kernel config is unknown:

- [ ] Identify kernel source repository (see [per-soc.md](per-soc.md) for your SoC)
- [ ] Clone kernel source
- [ ] Identify the correct defconfig for recovery
- [ ] Enable missing CONFIG options (see [kernel.md](kernel.md))
- [ ] Build kernel:
  ```bash
  make -j$(nproc) CC=clang CROSS_COMPILE=aarch64-linux-gnu- \
    CLANG_TRIPLE=aarch64-linux-gnu- Image.gz
  ```
- [ ] Replace stock kernel:
  ```bash
  cp arch/arm64/boot/Image.gz build/unzip_boot/kernel
  ```
- [ ] **Test-flash** a minimal build (with only kernel replaced) and confirm the device boots into recovery
- [ ] Run `droidspaces check` after flashing custom kernel and confirm it passes

---

## Phase 3: SELinux

These steps are identical on all devices.

### 3.1 Patch sepolicy binary with magiskpolicy

```bash
cd build/unzip_boot/root/

# Download magiskpolicy if not already present:
# https://github.com/topjohnwu/Magisk/releases

./magiskpolicy --load sepolicy --save sepolicy '
allow adbd adbd process setcurrent
allow adbd su process dyntransition
permissive { adbd }
permissive { su }
permissive { recovery }
'
```

- [ ] `sepolicy` has been patched and file size changed

### 3.2 Add selinux-permissive runtime script

```bash
cat > build/unzip_boot/root/system/bin/selinux-permissive << 'EOF'
#!/system/bin/sh
echo 0 > /sys/fs/selinux/enforce
EOF
chmod 755 build/unzip_boot/root/system/bin/selinux-permissive
```

- [ ] Script exists at `/system/bin/selinux-permissive`

### 3.3 Add selinux-permissive service and trigger to init.rc

In `build/unzip_boot/root/system/etc/init/hw/init.rc`, add to `on init`:
```
on init
    start selinux-permissive
```

And at end of file, add service:
```
service selinux-permissive /system/bin/selinux-permissive
    disabled
    oneshot
    user root
    group root
    seclabel u:r:recovery:s0
```

- [ ] `on init` trigger starts selinux-permissive
- [ ] Service definition added

---

## Phase 4: ADB Root

These steps are identical on all devices.

### 4.1 Modify prop.default

In `build/unzip_boot/root/prop.default`, change/add:
```
ro.secure=0
ro.adb.secure=0
ro.debuggable=1
service.adb.root=1
ro.force.debuggable=1
```

- [ ] Properties updated

### 4.2 Add ro.force.debuggable to plat_property_contexts

In `build/unzip_boot/root/plat_property_contexts`, add:
```
ro.force.debuggable u:object_r:build_prop:s0 exact bool
```

- [ ] Property context entry added

### 4.3 Add post-fs-data USB trigger to init.rc

In `build/unzip_boot/root/system/etc/init/hw/init.rc`, add:
```
on post-fs-data
    setprop sys.usb.config adb
```

- [ ] ADB trigger added

---

## Phase 5: USB ConfigFS

The adbd service definition and ConfigFS gadget setup. Most of this is universal; the USB controller node is device-specific.

### 5.1 Find the USB controller node for this device

```bash
# While device is in Android (USB connected):
adb shell ls /sys/bus/platform/devices/ | grep -iE "usb|udc"
# OR
adb shell cat /sys/class/udc/*/uevent | grep DRIVER
```

Note the device node name (e.g., `11201000.usb0`, `a600000.usb`, `4e00000.ssusb`).

- [ ] USB controller node identified: `_____________`

### 5.2 Create init.recovery.usb.rc

Copy `build/unzip_boot/root/system/etc/init/init.recovery.usb.rc` from this project directly — it is completely universal. The ConfigFS gadget setup is identical across all devices.

Only the `sys.usb.controller` property value changes. This is set in the device's hardware init file (e.g., `init.recovery.mt6835.rc` for the reference device). Find and update:

```bash
grep -r "sys.usb.controller" build/unzip_boot/root/
```

Update the value to match the USB controller node identified above.

- [ ] `init.recovery.usb.rc` present (copy from reference or create)
- [ ] `sys.usb.controller` set to the correct device node

### 5.3 Remove inline USB gadget logic from init.rc if present

If the stock `init.rc` has inline USB gadget service definitions and property triggers (as the reference device had before commit `96dbf77`), remove them to avoid duplicates with `init.recovery.usb.rc`.

- [ ] No duplicate adbd/fastbootd service definitions in init.rc

---

## Phase 6: Shell Environment

Universal — copy directly from reference project.

```bash
cat > build/unzip_boot/root/system/etc/environment << 'EOF'
#!/system/bin/sh
export PS1='$(whoami)@$(hostname):$PWD # '
EOF
```

In `init.rc`, add `export ENV /system/etc/environment` to the `on init` block.

- [ ] `/system/etc/environment` created
- [ ] `ENV` exported in `on init`

---

## Phase 7: Remove Vendor-Specific Cruft

### Samsung devices only:

- [ ] Check for and remove `dsms` binary: `rm -f build/unzip_boot/root/system/bin/dsms`
- [ ] Remove `dsms.rc`: `rm -f build/unzip_boot/root/system/etc/init/dsms.rc`
- [ ] Remove `dsms_common.rc`: `rm -f build/unzip_boot/root/system/etc/init/dsms_common.rc`
- [ ] Remove inline DSMS references from `init.rc` (any `start dsmsd` or `service dsmsd` blocks)

### Disable stock recovery UI (all devices):

In `init.rc`, add `disabled` to the `recovery` service:
```
service recovery /system/bin/recovery
    ...
    disabled    ← add this
```

- [ ] Stock recovery service disabled

---

## Phase 8: Add Droidspaces Binaries

### 8.1 Copy the droidspaces binary

```bash
cp build/unzip_boot/root/system/bin/droidspaces \
   /path/to/target_device/build/unzip_boot/root/system/bin/droidspaces
```

The `droidspaces` binary is statically linked and runs on any ARM64 Linux kernel. No modification needed.

- [ ] `droidspaces` binary present at `/system/bin/droidspaces`

### 8.2 Copy the recovery-console binary

```bash
cp build/unzip_boot/root/system/bin/recovery-console \
   /path/to/target_device/build/unzip_boot/root/system/bin/recovery-console
```

⚠️ The backlight path `/sys/devices/platform/soc/soc:mtk_leds/leds/lcd-backlight/brightness` is hardcoded in this binary. On non-MTK devices, brightness control will fail silently. The display will still work.

- [ ] `recovery-console` binary present at `/system/bin/recovery-console`

### 8.3 Copy and configure boot-ubuntu.sh

```bash
cp build/unzip_boot/root/system/bin/boot-ubuntu.sh \
   /path/to/target_device/build/unzip_boot/root/system/bin/boot-ubuntu.sh
```

Edit `ROOTFS_PATH` to point to the correct block device or image path for the target device:
- **SD card first partition**: `/dev/block/mmcblk0p1` (same or similar)
- **eMMC partition**: Find with `adb shell ls -la /dev/block/by-name/`
- **USB OTG storage**: `/dev/block/sda1` (if connected)

- [ ] `boot-ubuntu.sh` present and `ROOTFS_PATH` set correctly

### 8.4 Create init.ubuntu-droidspaces.rc

Copy `init.ubuntu-droidspaces.example.rc` and rename it (remove `.example`):

```bash
cp build/unzip_boot/root/system/etc/init/init.ubuntu-droidspaces.example.rc \
   /path/to/target/build/unzip_boot/root/system/etc/init/init.ubuntu-droidspaces.rc
```

No modification needed — the service definitions are universal.

- [ ] `init.ubuntu-droidspaces.rc` present (note: no `.example` suffix)

---

## Phase 9: Wi-Fi (Optional)

Wi-Fi is optional — skip if not needed.

- [ ] Identify the Wi-Fi chip family (see [per-soc.md](per-soc.md))
- [ ] Extract kernel module(s) from the device's vendor partition
- [ ] Extract firmware files from `/vendor/firmware/`
- [ ] Extract any required vendor binaries (WMT tools for MTK, cnss-daemon for Qualcomm, etc.)
- [ ] Write `init.wlan.rc` modeled on `init.mtk.wlan.rc` with device-correct paths
- [ ] Write `wlan_init.sh` modeled on the reference version with chip-appropriate init sequence
- [ ] Test: after flashing, `adb shell ifconfig wlan0` should show the interface

---

## Phase 10: Touch (Optional)

Touchscreen is optional — skip if not needed.

- [ ] Identify the touch controller IC (check device specs or `/proc/bus/input/devices` on live device)
- [ ] Extract touch module from `/vendor/lib/modules/`
- [ ] Extract touch firmware from `/vendor/firmware/`
- [ ] Extract helper modules (e.g., `sec_cmd.ko`, `tuihw-inf.ko` for Samsung, or equivalent for other OEMs)
- [ ] Create `init.touch.rc` modeled on the reference with correct module name and firmware path
- [ ] Test: after flashing, `/dev/input/event<N>` should appear

---

## Phase 11: First Flash Test

At this stage, do a minimal flash to verify the system boots and ADB works — before adding Droidspaces.

```bash
# Comment out the ubuntu-droidspaces services in init.ubuntu-droidspaces.rc temporarily
# OR simply don't add the file yet

./gradlew pack
fastboot flash recovery build/unzip_boot/../recovery.img.signed   # adjust path as needed
fastboot reboot recovery
```

Verification:
```bash
adb devices    # should show device in "recovery" transport
adb shell id   # should print "uid=0(root)"
adb shell uname -r    # should show expected kernel version
adb shell getenforce  # should print "Permissive"
adb shell /system/bin/droidspaces check  # should print "All required features found!"
```

- [ ] Device boots into recovery (not stock recovery UI)
- [ ] `adb devices` shows the device
- [ ] `adb shell id` returns `uid=0(root)`
- [ ] `getenforce` returns `Permissive`
- [ ] `droidspaces check` passes

---

## Phase 12: Full Droidspaces Boot

### 12.1 Prepare Ubuntu rootfs

Place your Ubuntu 24.04 ARM64 rootfs at the path configured in `boot-ubuntu.sh`. Options:

```bash
# Option A: SD card (recommended for development)
# Write Ubuntu 24.04 minimal ARM64 root filesystem image to SD card
dd if=ubuntu-24.04-minimal-arm64.img of=/dev/sdX bs=4M

# Option B: Image file on internal storage (requires booted recovery with ADB push)
adb push ubuntu-24.04-minimal-arm64.img /data/ubuntu.img
# Then set ROOTFS_PATH=/data/ubuntu.img in boot-ubuntu.sh
```

### 12.2 Enable the container init script

Add `init.ubuntu-droidspaces.rc` to the ramdisk (Phase 8.4) and reflash.

### 12.3 Boot test

```bash
fastboot flash recovery recovery.img.signed
fastboot reboot recovery
# Watch display: should show Ubuntu boot messages via recovery-console
# SSH into Ubuntu if configured, OR:
adb shell ps | grep droidspaces  # should show droidspacesd running
adb shell ps | grep ubuntu       # should show ubuntu-droidspaces
```

- [ ] `droidspacesd` is running
- [ ] `ubuntu-droidspaces` service started
- [ ] Ubuntu container boots to a shell or init
- [ ] Container output visible on device display (via recovery-console)

---

## Phase 13: Troubleshooting Checklist

If something doesn't work:

### ADB not connecting
- [ ] Check `sys.usb.controller` value matches actual USB controller node
- [ ] Verify `setprop sys.usb.config adb` is in `on post-fs-data`
- [ ] Check `adbd` service definition in `init.recovery.usb.rc`
- [ ] Try: `adb shell setprop sys.usb.config none; sleep 1; setprop sys.usb.config adb`

### Not root
- [ ] Verify `ro.secure=0`, `ro.adb.secure=0`, `service.adb.root=1` in `prop.default`
- [ ] Verify `adbd --root_seclabel=u:r:su:s0` in service definition
- [ ] Check SELinux: `getenforce` should be `Permissive`

### SELinux still enforcing
- [ ] Verify `selinux-permissive` script exists and is executable
- [ ] Verify `start selinux-permissive` is in `on init` (not `on boot`)
- [ ] Re-check magiskpolicy patch was applied to sepolicy

### droidspaces check fails after flashing custom kernel
- [ ] Run `adb shell /system/bin/droidspaces check` and read the output carefully
- [ ] For missing namespace types: add `CONFIG_*_NS=y` to defconfig and rebuild
- [ ] For missing OverlayFS: add `CONFIG_OVERLAY_FS=y` and rebuild
- [ ] For 4.14 kernels: add `--block-nested-namespaces` to `DS_FLAGS`

### Container doesn't start
- [ ] Check `adb shell dmesg | tail -50` for errors
- [ ] Check `adb shell logcat -d | grep -E "droidspaces|ubuntu|init"` 
- [ ] Verify `ROOTFS_PATH` in `boot-ubuntu.sh` exists: `adb shell ls -la /dev/block/mmcblk0p1`
- [ ] Verify droidspacesd is actually running: `adb shell ps | grep droidspaces`
- [ ] Try running manually: `adb shell /system/bin/boot-ubuntu.sh`

### Display blank (recovery-console not working)
- [ ] Check `adb shell dmesg | grep "dri\|DRM\|card0"`
- [ ] Verify `/dev/dri/card0` exists: `adb shell ls /dev/dri/`
- [ ] On non-MTK devices: backlight path failure is expected and silent — display should still work
- [ ] Try: `adb shell /system/bin/recovery-console` directly and observe any error output
