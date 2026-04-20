# Kernel Porting

The kernel is the single hardest part of any port. This document covers the full decision tree: how to check whether you even need a custom kernel, what to do if you do, and the pitfalls by platform.

---

## Step 1: Audit the Stock Kernel Before Touching Anything

Before assuming you need to rebuild, check what the stock kernel already supports. Many modern Android devices (especially those running Android 11+) already have most of the required config options enabled because GSI (Generic System Image) compliance mandates them.

### Extract and inspect kernel config from stock recovery

```bash
# Copy stock recovery.img to the repo root, then:
cp /path/to/stock/recovery.img recovery.img
./gradlew unpack
# Result:
cat build/unzip_boot/kernel_version.txt    # e.g. "5.10.198"
wc -l build/unzip_boot/kernel_configs.txt  # 0 = CONFIG_IKCONFIG not set
```

If `kernel_configs.txt` has content, check the critical options:

```bash
grep -E "^CONFIG_PID_NS|^CONFIG_IPC_NS|^CONFIG_NET_NS|^CONFIG_UTS_NS|\
^CONFIG_OVERLAY_FS|^CONFIG_CGROUPS|^CONFIG_CGROUP_NS|^CONFIG_USER_NS|\
^CONFIG_VETH|^CONFIG_DEVTMPFS|^CONFIG_LOOP|^CONFIG_FUSE_FS" \
  build/unzip_boot/kernel_configs.txt
```

Ideal output (all `=y`):
```
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_NET_NS=y
CONFIG_UTS_NS=y
CONFIG_OVERLAY_FS=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_NS=y
CONFIG_USER_NS=y
CONFIG_VETH=y
CONFIG_DEVTMPFS=y
CONFIG_LOOP=y
CONFIG_FUSE_FS=y
```

Any `# CONFIG_X is not set` or missing entry means that option is disabled in the stock kernel and a custom kernel build is required.

### Run droidspaces check on the live device

This is more reliable than config inspection because it tests actual kernel behavior, not just compile-time flags:

```bash
# Requires root on the device (via Magisk, Engineering mode, etc.)
adb push build/unzip_boot/root/system/bin/droidspaces /data/local/tmp/
adb shell chmod 755 /data/local/tmp/droidspaces
adb shell su -c '/data/local/tmp/droidspaces check'
```

A pass here means: **you do not need a custom kernel**. The stock kernel is sufficient for Droidspaces. You only need to update the init scripts, swap the `droidspaces` and `recovery-console` binaries into the ramdisk, apply the SELinux patches, and flash.

---

## Step 2: Decision Tree

```
droidspaces check passes on live device?
├── YES → No kernel rebuild needed. Proceed to ramdisk modifications.
└── NO → What is missing?
     │
     ├── Missing: namespace features (PID/IPC/UTS/MNT/NET)
     │    └── Is kernel source available?
     │         ├── YES → Enable in defconfig, rebuild (see below)
     │         └── NO  → Device is likely not portable without kernel source
     │
     ├── Missing: OverlayFS
     │    └── Is kernel 4.4+? Almost certainly rebuildable.
     │         Add CONFIG_OVERLAY_FS=y to defconfig.
     │
     ├── Missing: pivot_root
     │    └── This means the rootfs is ramfs-based. Recovery ramdisks are
     │         typically tmpfs (fine). If pivot_root truly fails, verify
     │         that /tmp is not mounted as ramfs in the recovery.
     │
     └── Missing: cgroups
          └── Cgroups are almost always enabled. If missing, the kernel
               source needs significant rework.
```

---

## Step 3: Finding Kernel Source

### Samsung

Samsung publishes GPL kernel sources for all Galaxy devices on their Open Source Release Center:

```
https://opensource.samsung.com/
```

Search by model number (e.g., `SM-A156E` for Galaxy A15 5G). Download the kernel source archive.

**Important Samsung kernel notes**:
- Samsung ships kernel sources with their own patches on top of the base Linux kernel
- The sources are typically for the full system kernel, not the recovery kernel
- Samsung recovery kernels are often stripped-down versions of the main kernel
- Some Samsung recovery kernels use a different defconfig than the system kernel

### Qualcomm (CodeAurora / GitHub CLO)

Qualcomm Android kernel sources are on Code Linaro Organization (CLO):

```
https://github.com/CodeLinaro    (current home after CLO migration)
https://git.codelinaro.org/clo/la/kernel/msm-5.15   (example)
```

Search by chipset: `msm-5.15` for SM8550, `msm-5.10` for SM8450, etc.

Vendor-specific patches are maintained by device OEMs; you usually start from the base CLO tree and add vendor patches from the device's kernel repository (e.g., `https://github.com/OnePlusOSS/android_kernel_oneplus_sm8550`).

### MediaTek

MediaTek kernel sources vary significantly by vendor and are less consistently published. Sources to try:

1. **Device OEM**: Most vendors using MTK chips publish sources on GitHub (e.g., `https://github.com/mt6895-devs`, TECNO, Infinix, Itel)
2. **MediaTek's own GitHub**: `https://github.com/mediatek-mt6*` — limited availability
3. **AOSP kernel/common**: For GKI-based kernels (Android 11+), MTK devices may use `https://android.googlesource.com/kernel/common` as a base

### Google Tensor

Pixel devices use the upstream ACK (Android Common Kernel):
```
https://android.googlesource.com/kernel/common
https://android.googlesource.com/kernel/gs (Tensor-specific)
```

Tensor kernels are typically the most open and best documented.

---

## Step 4: Identifying the Correct Defconfig

The kernel must be built with the right base defconfig. The wrong defconfig (e.g., a full system defconfig for a recovery kernel) may produce a kernel that boots but is far too large for the recovery partition, or is missing recovery-specific init support.

### Find the recovery defconfig

```bash
# In the kernel source tree:
ls arch/arm64/configs/ | grep -iE "recovery|debug|minimal"
# Common names:
# recovery_defconfig
# vendor/debug_defconfig
# vendor/SM-A156E_defconfig
# r10q_defconfig (Qualcomm style: r=recovery, device codename)
```

On Samsung: the recovery kernel often uses the same defconfig as the main kernel but with `CONFIG_SAMSUNG_RECOVERY=y` or similar.

On Qualcomm: look for `*_defconfig` files matching the chipset codename.

### Minimum additions to any defconfig for Droidspaces

If the existing defconfig doesn't have these, add them:

```
# Namespace support
CONFIG_PID_NS=y
CONFIG_IPC_NS=y
CONFIG_NET_NS=y
CONFIG_UTS_NS=y
CONFIG_CGROUP_NS=y
CONFIG_USER_NS=y

# OverlayFS
CONFIG_OVERLAY_FS=y

# Network (for --net=nat mode)
CONFIG_VETH=y
CONFIG_BRIDGE=y
CONFIG_NETFILTER=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_NF_TARGET_MASQUERADE=y

# Block device for image-backed rootfs
CONFIG_LOOP=y
CONFIG_BLK_DEV_LOOP=y

# Device access
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y

# FUSE (optional but common in Ubuntu containers)
CONFIG_FUSE_FS=y

# Cgroups
CONFIG_CGROUPS=y
CONFIG_CGROUP_SCHED=y
CONFIG_MEMCG=y
CONFIG_CPUSETS=y
CONFIG_PROC_PID_CPUSET=y
CONFIG_CGROUP_CPUACCT=y
CONFIG_CGROUP_BPF=y  # optional but helpful
```

---

## Step 5: Building the Kernel

### Generic ARM64 build process

```bash
# Set up cross-compilation toolchain (NDK r25+ or clang/gcc arm64)
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CLANG_PATH=/path/to/clang/bin
export PATH=$CLANG_PATH:$PATH

# Clean build environment
make mrproper

# Apply defconfig (use device-specific defconfig)
make vendor/your_device_defconfig

# Optional: interactive menu to add missing configs
make menuconfig

# Build (use -j$(nproc) for parallel)
make -j$(nproc) CC=clang CROSS_COMPILE=aarch64-linux-gnu- \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  Image.gz   # or Image, Image.lz4, depending on the device
```

The output kernel image is at `arch/arm64/boot/Image.gz` (or equivalent). This file replaces `build/unzip_boot/kernel`.

### Android GKI builds (kernel 5.10+, common kernel)

For GKI-based builds, the process is different — the kernel and modules are built separately and the kernel image is the GKI image:

```bash
# Clone android common kernel
git clone https://android.googlesource.com/kernel/common
cd common
git checkout android13-5.15

# Build with Bazel (GKI build system)
tools/bazel build //common:kernel_aarch64

# Output: out/android13-5.15/dist/Image.gz
```

GKI kernels are designed to be device-agnostic for the base image, with vendor-specific modules loaded separately. This is cleaner for portability but requires understanding the GKI split between core kernel and vendor modules.

---

## Kernel Version-Specific Issues

### Kernels 4.4–4.9

**Status**: Barely viable. Missing or broken OverlayFS, various namespace bugs.

- OverlayFS was merged in 3.18 but had significant bugs until 4.9
- `pivot_root` behavior with namespaces has known issues
- `CONFIG_USER_NS` often disabled by default (security concern)
- Cgroup v2 not available (v1 only)
- Droidspaces likely fails `check` without kernel patches

**Recommendation**: Avoid if possible. If the device only runs 4.4/4.9, porting is high-risk and requires non-trivial kernel patching.

### Kernels 4.14

**Status**: Functional but requires `--block-nested-namespaces` flag.

The `droidspaces` binary has an explicit workaround for 4.14:
```
--block-nested-namespaces
  (Blocks unshare/clone to fix VFS deadlocks on 4.14 kernels.
```

Add this to `DS_FLAGS` in `boot-ubuntu.sh` if the target device runs 4.14:
```sh
DS_FLAGS="--hw-access --privileged=full -B /tmp:/recovery --foreground --block-nested-namespaces"
```

### Kernels 4.19 / 5.4

**Status**: Good. Most required features are available and stable.

- OverlayFS is stable
- Namespaces work correctly
- Both cgroup v1 and v2 supported (v2 may need `cgroup_no_v1=all` kernel parameter)
- This is the "sweet spot" for Android devices from 2019–2021

### Kernels 5.10 / 5.15 (reference device kernel version)

**Status**: Best. Native cgroup v2 support, stable OverlayFS, all namespace types solid.

This is the kernel version of the reference device. All features work without workarounds.

### Kernels 6.1+ (Android 14+ devices)

**Status**: Unknown for Droidspaces specifically. Standard Linux features all present.

Newer kernels have additional security constraints (landlock, seccomp, BPF LSM) that may interact with container operations. The `noseccomp` flag in `droidspaces --privileged=noseccomp` likely addresses the seccomp side. With `--privileged=full` this should be bypassed.

---

## The `recovery-console` Binary and Non-MTK Displays

The `recovery-console` binary uses **DRM/KMS** (`/dev/dri/card0`) for display output, which is the standard Linux graphics interface. However, it has one **hardcoded MTK-specific path**:

```
/sys/devices/platform/soc/soc:mtk_leds/leds/lcd-backlight/brightness
```

This path controls the display backlight and is specific to MediaTek MT-series SoCs. On a non-MTK device, this path will not exist and the backlight control will silently fail — but the display will still work (just at whatever backlight level the bootloader left it at).

**For a clean port**: Find the equivalent backlight sysfs path on the target device:

```bash
# On the target device (while booted into Android):
adb shell ls /sys/class/backlight/
adb shell cat /sys/class/backlight/panel0-backlight/brightness  # common path
# OR
adb shell find /sys -name "brightness" 2>/dev/null | grep -v power
```

Unfortunately, `recovery-console` is a pre-built binary with this path hardcoded — it cannot be edited without recompiling. If display brightness control is important, this requires either accepting the limitation or obtaining a recompiled `recovery-console` targeting the new device.

**The display itself** (rendering to screen) uses `/dev/dri/card0` and standard DRM atomic API, which is vendor-neutral and works on any Linux DRM driver (Mali, Adreno, PowerVR, etc.).

---

## Verifying the New Kernel Works

After building and flashing the custom kernel via the ramdisk:

1. Boot into recovery
2. Confirm kernel version: `adb shell uname -r`
3. Run the feature check: `adb shell /system/bin/droidspaces check`
4. Check that modules loaded: `adb shell lsmod`
5. Check OverlayFS: `adb shell mount | grep overlay`
6. Check namespaces: `adb shell ls /proc/1/ns/`
7. Confirm cgroups: `adb shell mount | grep cgroup`
