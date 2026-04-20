# Per-SoC Porting Notes

This document covers the platform-specific obstacles and requirements for each major Android SoC family.

---

## Qualcomm Snapdragon

### Feasibility: High

Qualcomm devices are generally the most portable targets after Google Pixel. The CAF (Code Aurora Forum / CLO) kernel sources are well-maintained, the Android ecosystem is mature, and `fastboot` is universally supported.

### Kernel

**Source availability**: Excellent. Every Qualcomm kernel used in commercial devices is published on CLO (Code Linaro Organization), and most OEMs additionally publish their device-specific fork on GitHub.

**Typical kernel versions by chipset generation**:

| Chipset | Generation | Typical Kernel |
|---------|-----------|----------------|
| SDM835, SDM845 | 2017–2018 | 4.4 or 4.9 |
| SM7125, SM7150, SM6150 | 2019–2020 | 4.14 or 4.19 |
| SM8250, SM8350 | 2020–2021 | 5.4 |
| SM8450, SM8475 | 2022 | 5.10 |
| SM8550, SM8650 | 2023–2024 | 5.15 or 6.1 |
| SM7450, SM7550 | 2022–2023 | 5.10 or 5.15 |

**Namespace support in stock kernels**: Most Qualcomm kernels from 4.19+ have all required namespace configs already enabled (Google requires them for GSI compliance). For 4.14 and older, individual options may need enabling.

**Defconfig location** (in kernel source):
```
arch/arm64/configs/vendor/
  ├── <device_codename>_defconfig  # device-specific
  └── <chipset>_GKI.config          # GKI fragment (Android 12+)
```

### Wi-Fi

Qualcomm devices use the QCN/WCN family of Wi-Fi chipsets:

| Wi-Fi Chip | Driver | Module name |
|-----------|--------|-------------|
| WCN3990 (SDM845) | `cnss2` | `wlan.ko` (CNSS framework) |
| WCN6750 (SM8450+) | `cnss2` | Integrated |
| QCA6390, QCA6391 | `cnss2` | `wlan.ko` |
| WCN3615 (older) | `wcnss_wlan` | `wlan_prealloc.ko`, etc. |
| QCA6174 | `ath10k` (upstream) | `ath10k_core.ko`, `ath10k_pci.ko` |
| WCN3610 | `wcnss_wlan` | |

**CNSS-based Wi-Fi** (most SM6xxx/SM7xxx/SM8xxx devices): The `cnss2` driver requires a firmware daemon (`cnss-daemon`) running in the background to handle coexistence. This is the Qualcomm equivalent of MTK's `wmt_launcher`. The daemon binary and firmware files are in the vendor partition:

```
/vendor/bin/cnss-daemon    # firmware coexistence daemon
/vendor/firmware/          # contains wlan firmware
/vendor/etc/wifi/          # WCNSS_qcom_cfg.ini, etc.
```

Init script pattern for Qualcomm WLAN in recovery:
```rc
service wlan_pld /system/bin/sh /system/bin/wlan_init.sh
    user root; group root; oneshot; disabled; seclabel u:r:recovery:s0

on boot
    insmod /vendor/lib/modules/wlan.ko
    start wlan_pld
```

The `wlan_init.sh` equivalent for Qualcomm:
```sh
#!/system/bin/sh
# Load firmware via cnss framework
echo "ath10k" > /sys/kernel/debug/driver_name  # or qca6174, etc.
# OR for CNSS2:
echo on > /sys/bus/platform/devices/18800000.qcom,qca6390/power/wakeup
/vendor/bin/cnss-daemon -n -l &
ifconfig wlan0 up
```

Note: Qualcomm Wi-Fi initialization via CNSS is significantly more complex than the MTK WMT approach, and the exact procedure is device-specific. Expect to spend time researching the specific chipset.

### ADB and Fastboot

Universal. All Qualcomm devices support `fastboot`. `adbd` in recovery works identically to the reference device. The USB controller device node differs per chipset:

Common Qualcomm USB controller nodes (for `sys.usb.controller` in init):
```
"a600000.usb"    # SDM845
"a8c0000.hsusb"  # SM8250
"a600000.usb"    # SM8350, SM8450
"a4f8800.usb"    # SM7150
```

Find the correct node: `adb shell ls /sys/bus/platform/devices/ | grep usb`

### Display

Qualcomm uses the MDSS (Mobile Display Subsystem) DRM driver. `/dev/dri/card0` is available on all modern Qualcomm devices. `recovery-console` will open `card0` successfully.

**Backlight path** (replace the MTK hardcoded path in `recovery-console` behavior):
```bash
# Find on target device:
adb shell ls /sys/class/backlight/
# Typically: panel0-backlight, lcd-backlight, or similar
# Path: /sys/class/backlight/panel0-backlight/brightness
```

Since `recovery-console` has the MTK backlight path hardcoded, on Qualcomm devices the brightness control will fail silently. The display will work; it just won't be at optimal brightness.

### SELinux

Qualcomm recovery sepolicy is less locked down than Samsung. The same `magiskpolicy` patch applied in this project works identically.

---

## Samsung Exynos

### Feasibility: Medium

Samsung Exynos SoCs are used in Samsung Galaxy devices sold in certain regions (Europe, South Korea, some others). The kernel sources are available but less well-maintained than Qualcomm. The Wi-Fi situation is complex.

### Kernel

Samsung publishes Exynos kernel sources on the Samsung Open Source Release Center. Search by model number at `https://opensource.samsung.com/`.

**Typical kernel versions**:

| Chipset | Device | Typical Kernel |
|---------|--------|----------------|
| Exynos 9820 | Galaxy S10 | 4.14 |
| Exynos 990 | Galaxy S20 | 5.4 |
| Exynos 2100 | Galaxy S21 | 5.4 |
| Exynos 2200 | Galaxy S22 | 5.10 |
| Exynos 2400 | Galaxy S24 | 5.15 |

**Common issues with Samsung Exynos kernels**:
- Samsung adds many proprietary patches that are not upstreamed
- Recovery kernel defconfigs are often not separate from system defconfigs
- Some Samsung kernels have `CONFIG_USER_NS` disabled (by policy decision)
- `CONFIG_OVERLAY_FS` is sometimes disabled in recovery kernels specifically

### Wi-Fi

Samsung Exynos devices typically use Broadcom/Cypress WLAN chips:

| Device | Wi-Fi Chip | Driver |
|--------|-----------|--------|
| Galaxy S10/S20/S21 | BCM4375 | `dhd` (Broadcom FMAC) |
| Galaxy S22 | BCM4389 | `dhd` |
| Galaxy S24 | BCM4398 | `dhd` |

The Broadcom DHD driver requires:
1. A firmware binary: `/vendor/etc/wifi/bcmdhd_apsta.bin` or similar
2. An NVRAM file: `/vendor/etc/wifi/nvram_net.txt`
3. The DHD kernel module: `dhd.ko`

Init pattern for Broadcom DHD:
```rc
service wlan-init /system/bin/sh /system/bin/wlan_init.sh
    user root; group root; oneshot; disabled; seclabel u:r:recovery:s0

on boot
    insmod /vendor/lib/modules/dhd.ko
    start wlan-init
```

`wlan_init.sh` for Broadcom:
```sh
#!/system/bin/sh
ifconfig wlan0 up
```

The DHD driver handles its own firmware loading and initialization internally (unlike MTK which needs a separate WMT daemon). Simpler init procedure, but the module must be correctly loaded first.

### Knox and Secure Boot

**Knox**: Samsung Exynos devices have the same Knox mechanism as Samsung MTK devices. OEM unlock in Developer Options is required before any custom image can be flashed. Knox bit is tripped on unlock.

**Secure Boot with Samsung Certificate Authority**: Samsung signs their boot images with a Samsung Certificate Authority key. When OEM unlock is disabled, ANY image without this signature is rejected. When OEM unlock is enabled and the bootloader is unlocked, the Samsung CA check is bypassed.

**Note**: There are reports of Samsung enforcing signature checks even after OEM unlock on some carrier variants (T-Mobile USA, certain Verizon models). This is region/carrier-specific.

### Samsung Recovery UI

Samsung Exynos devices have the same stock Samsung Recovery UI that needs to be disabled (mark `recovery` service as `disabled`). Same approach as the reference device.

Same Samsung-specific files to remove:
- DSMS: `dsms`, `dsms.rc`, `dsms_common.rc` (present on all Samsung recovery images)
- Samsung RIL recovery integration (varies by model)

---

## MediaTek (Non-MT6835)

### Feasibility: Medium to High

Most of the work in this project is directly applicable to other MTK devices since the reference device is already MTK. The Wi-Fi and touch driver modules change, but the WMT/CONNAC framework is similar across MTK SoCs.

### Chipset Comparison

| Chipset | Series | Devices | Typical Kernel |
|---------|--------|---------|----------------|
| MT6765 | Helio G85, G88 | Budget Samsung, Xiaomi, Infinix | 4.19 |
| MT6769 | Dimensity 700 | Mid-range Samsung | 5.4 |
| MT6789 | Dimensity 6100+ | Reference device MT6835 equiv. | 5.15 |
| MT6833 | Dimensity 700G | Various | 5.10 |
| MT6853 | Dimensity 720 | | 5.4 |
| MT6873 | Dimensity 800 | | 5.4 |
| MT6877 | Dimensity 900 | | 5.10 |
| MT6893 | Dimensity 1200 | | 5.4 |
| MT6983 | Dimensity 9000 | | 5.10 |
| MT6985 | Dimensity 9200 | | 5.15 |

### Wi-Fi — Key Differences from MT6835

Most MTK devices use the same gen4m WLAN driver family (`wlan_drv_gen4m_*.ko`), but the **chip-specific variant changes**:

| MTK SoC | Wi-Fi Chip | Driver Module |
|---------|-----------|---------------|
| MT6835 (reference) | MT6631 | `wlan_drv_gen4m_6835.ko` |
| MT6853 | MT7663 | `wlan_drv_gen4m_6853.ko` |
| MT6877 | MT7922 | `wlan_drv_gen4m_6877.ko` |
| MT6983 | MT7902 | `wlan_drv_gen4m_6983.ko` |
| MT6789 | MT6635 | `wlan_drv_gen4m_6789.ko` |

The `WMT_SOC.cfg` and `connsys_*.bin` firmware files also change per chip. Extract these from the vendor partition of the target device:

```bash
adb shell ls /vendor/firmware/ | grep -E "connsys|WMT"
# Copy to the ramdisk's /vendor/firmware/
```

The `wmt_loader` and `wmt_launcher` binaries may differ between MTK SoC families but often the same binary works across chips (the WMT protocol is standardized within MTK).

The `init.mtk.wlan.rc` script from this project is largely reusable. Change:
1. The modprobe target module name: `wlan_drv_gen4m_6835.ko` → `wlan_drv_gen4m_XXXX.ko`
2. The nvdata partition: `/dev/block/sdc28` may differ — find with `adb shell ls -la /dev/block/by-name/ | grep nvdata`

### Touch — Different Controllers

The reference device uses FocalTech FT3419U. Other MTK devices commonly use:

| Controller | Driver Module | Common OEM |
|-----------|---------------|-----------|
| FocalTech FT3419U (reference) | `focaltech_tp.ko` | Samsung budget |
| FocalTech FT5446 | `focaltech_tp.ko` | Many |
| Goodix GT9xx | `goodix_ts.ko` | Xiaomi, OPPO budget |
| ILITEK ILI9882 | `ilitek_ts_mptest.ko` | Various |
| Synaptics S3706 | `synaptics_tcm_hid.ko` | Samsung mid-range |
| Himax HX83102 | `himax_ts.ko` | MediaTek reference boards |
| Novatek NT36xxx | `nt36xxx.ko` | OPPO, Xiaomi, Realme |

Extract the touch module and firmware from the device's `vendor` partition:
```bash
adb shell ls /vendor/lib/modules/ | grep -iE "touch|tp|ts|focaltech|goodix|novatek|synaptics|himax"
adb pull /vendor/lib/modules/<touch_module>.ko
adb shell ls /vendor/firmware/ | grep -iE "tp|touch|ts|fw"
```

The init pattern is the same as `init.touch.rc` in this project — just change the module name.

### USB Controller Node

The MTK USB controller node address changes per SoC:

| MTK SoC | USB controller node |
|---------|-------------------|
| MT6835 (reference) | `11201000.usb0` |
| MT6853 | `11201000.usb0` |
| MT6873 | `11201000.usb0` |
| MT6983 | `11200000.usb0` |

Find for any device: `adb shell ls /sys/bus/platform/devices/ | grep -i usb`

---

## Google Tensor (Pixel 6+)

### Feasibility: Very High

Google Pixel devices are the easiest Android targets for any kind of system-level modification. Bootloader unlock is simple and well-documented, kernel sources are fully public, and there are no Samsung Knox or OEM-specific lock-down mechanisms.

### Kernel

Google Tensor kernel sources are on AOSP:
```
https://android.googlesource.com/kernel/gs  (Tensor GS101, GS201)
https://android.googlesource.com/kernel/gs201  (Tensor G2)
https://android.googlesource.com/kernel/gs301  (Tensor G3)
```

All GKI-compliant. Kernels 5.10, 5.15, and 6.1 depending on Pixel generation.

**The stock kernel already passes `droidspaces check`** on most Pixel devices — no custom kernel needed.

### Wi-Fi

Pixel 6+ uses Samsung WLAN chips:

| Device | Chip | Driver |
|--------|------|--------|
| Pixel 6/6a | Samsung S5123 | `bcmdhd.ko` variant |
| Pixel 7/7a | Samsung S5300 | `bcmdhd.ko` |
| Pixel 8/8a | Samsung S5400 | `bcmdhd.ko` |

Same Broadcom DHD driver approach as Samsung Exynos devices (simpler than MTK WMT).

### Partition Layout

Pixel 6+ uses Virtual A/B with `init_boot` (Android 13 on Pixel 7+). Recovery modifications go to `vendor_boot.img`. See [recovery-formats.md](recovery-formats.md).

### No Knox, No DSMS

No Samsung Knox equivalent. No DSMS to remove. SELinux patching is simpler because stock Pixel sepolicy already allows more developer operations.

---

## UNISOC (Spreadtrum)

### Feasibility: Low

UNISOC (formerly Spreadtrum) is used in ultra-budget Android devices (sub-$100 phones). Porting is difficult due to:

1. **No public kernel sources**: UNISOC does not consistently publish kernel sources. Device OEMs rarely publish them either.
2. **No standard fastboot**: Most UNISOC devices require SP Flash Tool (ResearchDownload Tool specifically) for flashing.
3. **Proprietary kernel modules**: Wi-Fi, modem, and many other subsystems use closed-source binary kernel modules.
4. **Old kernels**: 4.4 or 4.9 with many UNISOC-proprietary patches.
5. **ARM32 on older chips**: SC7731 and similar chips are ARM32 (ARMv7), incompatible with the ARM64 `droidspaces` and `recovery-console` binaries.

**ARM64 UNISOC chips** (newer): UMS9230, T606, T616, T618, T700, T760, T770, T820.

If the device is ARM64 and kernel sources can be obtained (check device OEM GitHub, e.g., some Transsion/TECNO devices publish sources), porting may be feasible but still requires significant work.

---

## Summary Table

| SoC Family | Feasibility | Kernel Source | Wi-Fi Complexity | Flash Tool | Notes |
|-----------|-------------|--------------|-----------------|------------|-------|
| Qualcomm Snapdragon (2020+) | High | Excellent (CLO) | Moderate (CNSS2) | fastboot | Best non-Google option |
| Google Tensor | Very High | Excellent (AOSP) | Low (BCM DHD) | fastboot | Easiest overall |
| MediaTek (other MT6xxx) | High | Good (OEM GitHub) | Low (same WMT) | fastboot or SP Flash | Similar to reference device |
| Samsung Exynos (2020+) | Medium | Good (Samsung OSS) | Moderate (BCM DHD) | Odin/heimdall | Knox, carrier locks |
| Qualcomm Snapdragon (pre-2019) | Medium | Good but old | High (CNSS1/legacy) | fastboot | Old kernels need work |
| Samsung Exynos (pre-2019) | Medium-Low | Mediocre | Hard (various) | Odin/heimdall | 4.14 kernel issues |
| MediaTek (old MT67xx) | Low-Medium | Spotty | Hard (old WMT) | SP Flash Tool | 4.19 or older |
| UNISOC | Low | Poor or none | Very Hard | ResearchDownload | Often ARM32 |
| Huawei Kirin | Not feasible | None (post-2018) | N/A | HiSuite locked | Bootloader locked by eFuse |
