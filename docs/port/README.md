# Porting Guide — Overview

This directory documents the feasibility and process of porting this recovery hack to Android devices other than the Samsung MT6835 target this project was built on.

---

## Short Answer

**It is feasible for any device with an unlocked bootloader, but the amount of work varies enormously by device.**

| Component | Portability | Work Required |
|-----------|-------------|---------------|
| `droidspaces` binary | **Universal** (statically linked ARM64, standard Linux syscalls) | None — runs on any ARM64 Android device |
| SELinux patching | **Universal** (magiskpolicy works on all Android devices) | None — process is identical |
| Property bypasses | **Universal** | None — same properties on all AOSP-based devices |
| ADB root setup | **Universal** | None — same approach everywhere |
| USB ConfigFS init | **Near-universal** | Minimal — update `sys.usb.controller` device node |
| Shell environment | **Universal** | None |
| `recovery-console` | **MTK-dependent** | Moderate — display server has MTK-specific backlight path; DRM is more portable |
| Wi-Fi driver stack | **Completely device-specific** | High — must source correct firmware, modules, and WMT tooling per SoC |
| Touch driver | **Completely device-specific** | High — must source correct `.ko`, firmware, and init script per controller |
| Kernel replacement | **Device-specific** | **Critical and hardest** — need kernel source + required `CONFIG_` options enabled for target SoC |
| Recovery image format | **Platform-specific** | Moderate — Samsung vs. Qualcomm vs. MTK vs. A/B vs. Virtual A/B all differ |

---

## Documents in This Directory

### [requirements.md](requirements.md)
What a target device needs to be a viable porting target: bootloader unlock, kernel config requirements, Droidspaces `check` command output interpretation, partition layout requirements.

### [kernel.md](kernel.md)
The hardest part of any port. How to audit a stock kernel, what config options Droidspaces needs, how to check without reflashing, rebuilding from source, and known issues per kernel version.

### [recovery-formats.md](recovery-formats.md)
How recovery image formats differ across Samsung (Odin), Qualcomm (fastboot), MediaTek (SP Flash Tool), A/B partition devices, and Virtual A/B (VAB) devices — and how to handle each with this toolchain.

### [per-soc.md](per-soc.md)
SoC-specific porting notes for Qualcomm Snapdragon, Samsung Exynos, MediaTek (other chips), Google Tensor, and UNISOC. Covers known kernel source availability, Wi-Fi/BT chip families, and platform-specific obstacles.

### [checklist.md](checklist.md)
Step-by-step porting checklist. Work through this sequentially for any new device.

---

## Feasibility Tiers

Based on analysis of this project's components, target devices fall into three rough tiers:

### Tier 1: High Feasibility (< 1 day of work)

**Criteria**: Device runs Android 10+, ARM64, unlocked bootloader, standard AOSP recovery (not Samsung), kernel 4.9+ with namespaces enabled, uses standard fastboot flashing.

**Examples**: Google Pixel (3+), many OnePlus devices, Xiaomi with unlocked bootloader, most stock AOSP GSI-compatible devices.

**Why easy**: The `droidspaces` binary, SELinux patches, and property changes are completely universal. The kernel likely already has the required namespace and cgroup configs. The `recovery-console` DRM path (`/dev/dri/card0`) works on most DRM-capable kernels. No DSMS to remove. Standard fastboot flashing.

### Tier 2: Moderate Feasibility (1–3 days)

**Criteria**: Samsung device (non-MT6835), OR any device where the stock kernel is missing some namespace configs, OR devices with A/B partitions requiring boot.img modification instead of recovery.img.

**Examples**: Samsung Galaxy (Exynos or other MTK), OnePlus with A/B, many MediaTek devices from other vendors.

**Why moderate**: Need to either compile a custom kernel or verify that stock kernel passes `droidspaces check`. Samsung-specific Samsung Recovery UI and DSMS cleanout is still needed. A/B devices require modifying `boot.img` instead of `recovery.img`. `recovery-console`'s backlight path needs updating.

### Tier 3: Difficult (days to weeks, may not be fully feasible)

**Criteria**: Samsung device with Knox tripped or non-bypassable AVB enforcement, device with locked bootloader that requires signed kernels, device with no public kernel source, very old kernel (< 4.4), or device requiring Samsung Odin signing for EVERY flash.

**Examples**: Samsung devices where OEM unlock was never enabled, Huawei after 2018 bootloader lock, heavily locked carrier variants, devices with eFuse-burned AVB keys.

**Why hard**: Without kernel source, a custom kernel with the required config options cannot be built. Without an unlocked bootloader, there is no way to flash a modified recovery. Some Samsung carrier variants will reject unsigned recovery images even after OEM unlock; Knox is tripped (hardware eFuse) but the device does not become fully unusable.
