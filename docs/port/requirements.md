# Device Requirements

## Hard Requirements (No Workaround)

### 1. Unlocked Bootloader

The bootloader **must** be unlocked. This is non-negotiable — a locked bootloader will reject any modified recovery image, even if signed.

What "unlocked" means varies by OEM:

| OEM | Unlock mechanism | Notes |
|-----|-----------------|-------|
| Google Pixel | `fastboot flashing unlock` | Easiest. No DRM impact. |
| OnePlus | `fastboot oem unlock` | Standard |
| Xiaomi | MI Unlock Tool + 7-day wait | Requires Mi account binding |
| OPPO/Realme/Vivo | Varies, often via deep testing mode | Post-2021 models increasingly locked |
| Samsung | OEM unlock in Developer Options, then Odin | Trips Knox warranty bit (`0x1`). Some regions have OEM unlock disabled by carrier. |
| MediaTek (generic) | `fastboot oem unlock` or SP Flash Tool DA unlock | Varies heavily by vendor |
| Qualcomm (generic) | `fastboot oem unlock` or EDL + auth tokens | Some require device-specific unlock tokens from OEM |

**Samsung Knox**: Unlocking the Samsung bootloader trips the Knox warranty bit. This is a one-way hardware eFuse change. It does not prevent flashing custom images, but it does disable Samsung Pay, Samsung Pass, Knox Workspace, and some DRM features. It does NOT prevent this project from working.

### 2. ARM64 Architecture

Both `droidspaces` and `recovery-console` are compiled for ARM64 (AArch64). 32-bit ARM (ARM32/ARMv7) is not supported. All Android devices released after 2020 are ARM64. Devices from 2016–2019 may be ARM32 or have a 32-bit userspace on 64-bit kernel — check with `uname -m` or `adb shell getprop ro.product.cpu.abi`.

### 3. Android 9.0 (Pie) or Later

The recovery init system assumes AOSP init 2.0 behavior (property triggers, `seclabel`, etc.). Devices running Android 8 (Oreo) or earlier use a significantly different init system and the `.rc` files in this project will not work without modification. Most modern unlocked devices run Android 10+, so this is rarely an issue.

### 4. Linux Kernel 4.9 or Later (Recommended 5.4+)

Droidspaces performs a runtime feature check (`droidspaces check`) and will refuse to start if the kernel is too old or missing required features. Based on string analysis of the `droidspaces` v5.9.5 binary:

- It has a `--block-nested-namespaces` flag specifically for **4.14 kernels** that have VFS deadlock bugs with nested namespaces
- The OverlayFS implementation must be stable — earlier kernels had known bugs
- Network namespaces are required for NAT mode (`CONFIG_NET_NS`)
- `pivot_root` syscall must work (it fails on ramfs root — recovery ramdisks are **not** ramfs, they are tmpfs, so this works)

The reference device uses Linux **5.15.148**. Most Android devices from 2021+ ship 5.4 or 5.10. Older devices (2018–2020) typically ship 4.9 or 4.14.

---

## Checking Kernel Requirements Without Reflashing

Run `droidspaces check` in an ADB root shell on the target device (while it's booted into normal Android, after gaining root access via another method like Magisk):

```bash
adb root
adb push droidspaces /data/local/tmp/
adb shell chmod +x /data/local/tmp/droidspaces
adb shell /data/local/tmp/droidspaces check
```

Expected passing output:
```
Droidspaces v5.9.5
 Checking system requirements...
[+] All required features found!
```

Failed output (example):
```
[-] 3 required feature(s) missing - Droidspaces will not work
    Missing: PID namespace
    Missing: OverlayFS
    Missing: pivot_root syscall
```

If `droidspaces check` passes on a running Android system, the kernel is compatible. If it fails, see [kernel.md](kernel.md) for how to evaluate whether those features can be added.

---

## Kernel Configuration Requirements

These are the kernel `CONFIG_` options that Droidspaces v5.9.5 explicitly checks for or depends on based on its runtime error messages:

### Required (hard fail if missing)

| Config | Purpose | Error if absent |
|--------|---------|-----------------|
| `CONFIG_PID_NS` | PID namespace isolation | "PID namespace is not supported by the kernel" |
| `CONFIG_IPC_NS` | IPC namespace | "IPC namespace is not supported by the kernel" |
| `CONFIG_UTS_NS` | Hostname namespace | Namespace check failure |
| `CONFIG_NET_NS` | Network namespace | "CONFIG_NET_NS not compiled in. Network namespaces are required for --net=nat." |
| `CONFIG_MNT_NS` / mount namespaces | Filesystem isolation | "Mount namespace is not supported by the kernel" |
| `CONFIG_OVERLAY_FS` | OverlayFS | "OverlayFS is not supported by your kernel. Volatile mode cannot be used." |
| `CONFIG_CGROUPS` | Resource management | Cgroup-related failures |

### Required for specific features

| Config | Feature | Notes |
|--------|---------|-------|
| `CONFIG_VETH` | NAT networking (`--net=nat`) | "CONFIG_VETH not enabled... Rebuild your kernel with CONFIG_VETH=y" |
| `CONFIG_BRIDGE` | Bridged networking | "CONFIG_BRIDGE not supported - will fallback to bridgeless NAT" |
| `CONFIG_USER_NS` | User namespace mapping | Needed for rootless container operations |
| `CONFIG_CGROUP_NS` | Cgroup namespace | "Control Group namespace isolation" — listed as optional |
| `CONFIG_DEVTMPFS` | Hardware access mode | "this kernel does not support devtmpfs. GPU and hardware nodes may not be available" |
| `CONFIG_LOOP` | Loop device support | Needed for `-i <image>` rootfs mode |
| `CONFIG_FUSE_FS` | FUSE filesystem | Optional but common |

### How to check stock kernel config

Method 1 — from running device (Magisk root or similar):
```bash
adb shell zcat /proc/config.gz | grep -E "CONFIG_PID_NS|CONFIG_IPC_NS|CONFIG_NET_NS|CONFIG_OVERLAY_FS|CONFIG_CGROUPS|CONFIG_VETH|CONFIG_USER_NS|CONFIG_DEVTMPFS|CONFIG_LOOP"
```

Method 2 — from the unpacked kernel image using this toolchain:
```bash
./gradlew unpack   # creates build/unzip_boot/kernel_configs.txt
grep -E "CONFIG_PID_NS|CONFIG_IPC_NS|CONFIG_NET_NS|CONFIG_OVERLAY_FS|CONFIG_CGROUPS|CONFIG_VETH|CONFIG_USER_NS|CONFIG_DEVTMPFS|CONFIG_LOOP" build/unzip_boot/kernel_configs.txt
```

The Android boot image editor (`./gradlew unpack`) extracts the embedded kernel `.config` from the kernel image's `.config` section (placed there by `CONFIG_IKCONFIG`). Not all vendor kernels have this enabled — if `kernel_configs.txt` is empty after unpacking, the kernel was built without `CONFIG_IKCONFIG=y` and you cannot inspect the config this way.

Method 3 — read `/boot/config-*` on the device (some devices have this):
```bash
adb shell ls /boot/
```

---

## Partition Layout Requirements

### Option A: Dedicated recovery partition (classic A-only layout)

The simplest case. The device has a separate `recovery` partition that boots independently of the main Android system.

```
Flash: fastboot flash recovery recovery.img.signed
Boot:  fastbootd reboot recovery  OR  volume key combo
```

**Detection**:
```bash
fastboot getvar all 2>&1 | grep -i "slot\|recovery"
adb shell ls /dev/block/by-name/ | grep recovery
```

If `recovery` appears in the block device list, the device has a dedicated recovery partition.

### Option B: A/B partition layout (no recovery partition)

Devices launched with Android 8.0+ "Treble" may use A/B seamless updates. There is **no recovery partition** — recovery is embedded in `boot.img` itself. The bootloader selects between `boot_a` and `boot_b` slots; neither is dedicated to recovery.

On these devices, you must modify `boot.img` instead of `recovery.img`:
```bash
cp your_boot.img boot.img
./gradlew unpack
# ... make modifications to build/unzip_boot/root/
./gradlew pack
fastboot flash boot boot.img.signed
# OR: flash both slots
fastboot flash boot_a boot.img.signed
fastboot flash boot_b boot.img.signed
```

**Detection**:
```bash
fastboot getvar current-slot
fastboot getvar has-slot:recovery
```

If `has-slot:recovery` returns `no`, there is no recovery partition.

**Key difference**: On A/B devices, the "recovery" mode is triggered by a BCB (Bootloader Control Block) flag or a reboot reason. The ramdisk must support both normal boot and recovery mode. The modifications in this project (disabling the recovery binary, adding custom services) are still applicable, but the image format and flash target change.

### Option C: Virtual A/B (VAB, Android 11+)

The most complex partition scheme. Uses dynamic partitions with copy-on-write snapshots. VAB devices still have `boot_a`/`boot_b` but may also have `init_boot_a`/`init_boot_b` (Android 13+) where the ramdisk is split from the kernel.

On Android 13+ VAB devices with `init_boot`:
- `boot.img` contains only the kernel (no ramdisk)
- `init_boot.img` contains the generic ramdisk
- Recovery ramdisk is in `vendor_boot.img`

You would need to modify `vendor_boot.img` or `init_boot.img` depending on the specific device's layout.

**Detection**:
```bash
fastboot getvar dynamic-partition
fastboot getvar is-userspace        # if yes, you're in fastbootd, not bootloader fastboot
adb shell getprop ro.boot.dynamic_partitions
```

---

## AVB and Signing Requirements

### AVB 2.0 (this project's device)

The reference device uses Android Verified Boot 2.0 with a hash footer in the recovery image. The toolchain's `./gradlew pack` task automatically handles re-signing with the AOSP test keys from `aosp/security/`.

**For most unlocked bootloaders**: AVB verification is disabled after unlocking. The bootloader will show a warning ("Your device is unlocked and cannot be trusted") but will boot any image.

**For devices with custom AVB keys**: Some OEMs (notably Google with Pixel 3+) allow setting a custom AVB key. If the device has a custom key enrolled via `fastboot flash avb_custom_key`, only images signed with that key will boot silently. The AOSP test keys in this repo will still work if the bootloader is unlocked, but you'll see the unlock warning.

### Samsung-specific signing

Samsung devices have their own boot image signing layer on top of standard AVB. Samsung's Odin flashing tool checks for a Samsung-specific signature. However:
- When OEM unlock is enabled and the bootloader is unlocked, Odin's signature check is bypassed
- Heimdall (open-source Odin alternative) does not check Samsung signatures at all
- `fastboot` on Samsung devices (where supported) also bypasses Samsung-specific checks

**The test keys in `aosp/security/` are sufficient for flashing on unlocked Samsung devices.**

---

## What "Droidspaces Support" in the Kernel Actually Means

Based on string analysis, `droidspaces` v5.9.5 is a **statically linked, generic Linux container runtime** — it uses standard Linux syscalls (`clone`, `unshare`, `setns`, `pivot_root`, `mount`) with no SoC-specific kernel interfaces.

The "custom kernel with Droidspaces support" in this project (commit `8a63a39`) replaced the kernel binary but committed no source diff. Important context:

- The `kernel_configs.txt` in this repo was **not** updated by that commit — it reflects the **stock** recovery kernel config, which already shows `CONFIG_NAMESPACES=y`, `CONFIG_CGROUPS=y`, `CONFIG_OVERLAY_FS=y`, and all other required options enabled.
- The custom kernel binary is smaller (17.4 MiB vs. 20.4 MiB stock), suggesting a stripped-down build.
- The exact reason the stock kernel was insufficient (if it was) is not documented.

**For non-MTK devices, a stock kernel that passes `droidspaces check` is sufficient** — there is no evidence from string analysis that `droidspaces` requires any proprietary kernel module or non-standard kernel interface beyond standard Linux namespace/cgroup/OverlayFS support.
