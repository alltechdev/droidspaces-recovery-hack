# Recovery Image Formats

Different Android platforms use fundamentally different partition layouts and image formats. This page documents each variant and what it means for porting.

---

## Detecting Your Device's Layout

Run these commands from fastboot mode (power + volume-down, then select "fastboot", or `adb reboot fastboot`):

```bash
fastboot getvar all 2>&1 | tee fastboot_vars.txt

# Key vars to look for:
grep -E "slot-count|current-slot|has-slot|dynamic-partition|ab-update|recovery" fastboot_vars.txt
```

| Variable | Value | Meaning |
|----------|-------|---------|
| `slot-count` | `1` | A-only layout, dedicated recovery partition |
| `slot-count` | `2` | A/B layout, no dedicated recovery |
| `has-slot:recovery` | `yes` | Dedicated recovery partition exists |
| `has-slot:recovery` | `no` | No recovery partition, recovery is in boot |
| `dynamic-partition` | `true` | Uses dynamic partitions (super partition) |
| `is-userspace` | `true` | Currently in fastbootd (userspace fastboot, not bootloader fastboot) |

---

## Format 1: Classic A-only (dedicated `recovery` partition)

**Who uses it**: Older Samsung devices (pre-2019), some MediaTek budget phones, older Xiaomi, older OnePlus.

**Layout**:
```
/dev/block/by-name/
├── boot          (kernel + normal boot ramdisk)
├── recovery      (recovery kernel + recovery ramdisk) ← modify this
├── system
├── vendor
└── userdata
```

**This is the format used by the reference device.** The entire workflow in this project applies directly.

**Flash command**:
```bash
fastboot flash recovery recovery.img.signed
# Samsung with Odin:
# Put in recovery.img.signed as the AP (PDA) entry in Odin
```

**Boot into recovery**:
```bash
fastboot reboot recovery
# OR: power off, hold volume-up + power (Samsung), or device-specific combo
```

**Toolchain compatibility**: Full — `./gradlew unpack` and `./gradlew pack` work directly.

---

## Format 2: A/B Seamless Update (no dedicated recovery)

**Who uses it**: Google Pixel (2+), OnePlus (OnePlus 7+), most Qualcomm 2019+ flagships, Samsung Galaxy S21+ (Exynos regions), many modern MediaTek mid-range.

**Layout**:
```
/dev/block/by-name/
├── boot_a        (kernel + ramdisk for slot A) ← modify this
├── boot_b        (kernel + ramdisk for slot B) ← and this
├── system_a / system_b
├── vendor_a / vendor_b
└── userdata
```

No `recovery` partition. Recovery mode is triggered by writing a specific message to the BCB (Bootloader Control Block, in the `misc` partition) before rebooting.

**What changes for porting**:

1. Work with `boot.img` instead of `recovery.img`:
   ```bash
   cp /path/to/stock/boot.img boot.img   # or boot_a.img
   ./gradlew unpack
   # → now modifies build/unzip_boot/ same as before
   ./gradlew pack
   # → outputs boot.img.signed
   ```

2. The recovery.json will reference `boot.json` instead of `recovery.json` after unpacking

3. Flash **both** slots to avoid boot loops when the system switches slots:
   ```bash
   fastboot flash boot_a boot.img.signed
   fastboot flash boot_b boot.img.signed
   # OR if fastbootd supports it:
   fastboot --slot=all flash boot boot.img.signed
   ```

4. **Critical**: A/B boot images contain ramdisks that handle **both** normal boot and recovery mode. The `init` system checks for the reboot reason and mounts the appropriate filesystems. Do not blindly disable the `recovery` service — on A/B devices, the recovery binary is what handles recovery mode; it is needed.

   Instead, the approach should be to add the Droidspaces services **in addition to** the recovery service, and trigger them only when in recovery mode (e.g., via the `ro.bootmode=recovery` property).

5. **Recovery mode trigger** (boot into recovery on A/B device):
   ```bash
   adb reboot recovery
   # OR
   fastboot reboot recovery   # triggers BCB write and boots recovery ramdisk
   ```

**Header version note**: A/B boot images use header version 2 or higher. The `build/unzip_boot/boot.json` (or `recovery.json`) produced by unpack will contain the correct header version for repacking.

---

## Format 3: Virtual A/B (VAB) with `init_boot`

**Who uses it**: Devices launched with Android 13+, including Samsung Galaxy S22+ series (Android 13 launch), Google Pixel 7+, high-end MediaTek 2022+ (Dimensity 9000+).

**Layout** (Android 13+):
```
/dev/block/by-name/
├── boot_a / boot_b         (kernel ONLY — no ramdisk)
├── init_boot_a / init_boot_b  (generic ramdisk ← GKI split)
├── vendor_boot_a / vendor_boot_b  (vendor ramdisk + recovery ramdisk)
├── system_a / system_b     (dynamic, inside super)
├── vendor_a / vendor_b     (dynamic, inside super)
└── userdata
```

This is the GKI (Generic Kernel Image) split introduced in Android 12 and enforced in Android 13:
- `boot.img` = kernel image only (the GKI kernel)
- `init_boot.img` = AOSP generic ramdisk
- `vendor_boot.img` = vendor-specific ramdisk, **including the recovery ramdisk**

**For porting to VAB + init_boot devices**:

Recovery modifications go into `vendor_boot.img`:
```bash
cp /path/to/stock/vendor_boot.img vendor_boot.img
cp /path/to/stock/vbmeta.img vbmeta.img    # needed for signing
./gradlew unpack
# → extracts to build/unzip_boot/root/
# Make modifications to root/
./gradlew pack
# → outputs vendor_boot.img.signed and vbmeta.img.signed
fastboot flash vendor_boot vendor_boot.img.signed
fastboot flash vbmeta vbmeta.img.signed    # must update vbmeta when vendor_boot changes
```

The kernel itself is NOT modified — the stock GKI kernel is kept. Droidspaces kernel requirements are instead handled by verifying the GKI kernel config (most GKI kernels from Android 12+ have all required options enabled by default).

**Critical**: GKI kernels enforce ACK (Android Common Kernel) requirements that include `CONFIG_PID_NS=y`, `CONFIG_NET_NS=y`, `CONFIG_OVERLAY_FS=y`, and all other namespace options. This means on GKI devices, **no kernel rebuild is needed at all** — just ramdisk modifications.

---

## Format 4: Samsung Odin / Heimdall Flashing

Samsung devices use their own proprietary flashing protocol over USB rather than standard `fastboot`. The two tools for this are:

| Tool | Type | Protocol |
|------|------|---------|
| Odin (Windows) | Official Samsung, closed-source | Samsung Download Mode (USB 0x04E8 PID variants) |
| Heimdall | Open-source, cross-platform | Reverse-engineered Download Mode |

### Entering Download Mode

- Modern Samsung: `adb reboot download` OR power off, then press vol-down + vol-up simultaneously while connecting USB
- Older Samsung: power off, hold vol-down + home + power (varies by model)

### Flashing with Odin

1. Open Odin (Windows only)
2. Connect device in Download mode
3. In the **AP** slot, select `recovery.img.signed`
4. Ensure "Auto Reboot" is checked
5. Click Start

**Odin 3.14+**: If the image is too large or has an unexpected header, Odin may reject it. This is rare with properly packed images using the toolchain.

### Flashing with Heimdall

```bash
heimdall flash --RECOVERY recovery.img.signed --no-reboot
# Then manually reboot into recovery:
# volume-up + power (while device is off)
```

**Partition name**: The partition name used in Heimdall may vary. Check the partition table:
```bash
heimdall print-pit
```
Look for an entry with `PIT Name` containing "RECOVERY" or "AP_RECOVERY".

### Samsung-Specific Complication: `AP` Bundle vs Individual Image

Some Samsung models require the entire AP (Application Processor) bundle to be flashed — not just the recovery image. The AP bundle is a multi-image archive containing the kernel, ramdisk, and other components. In this case, only flashing the recovery partition alone may be insufficient; you might need to include the modified recovery in a full AP package.

For most modern Samsung devices, flashing just the recovery partition (AP slot in Odin, or `--RECOVERY` in heimdall) is sufficient.

---

## Format 5: MediaTek SP Flash Tool (No Fastboot)

Some low-end and mid-range MediaTek devices do not support standard `fastboot`. They use SP Flash Tool (Smart Phone Flash Tool, a.k.a. SPFT) for flashing.

**Detection**: If `fastboot devices` returns nothing even in fastboot mode, the device may require SP Flash Tool.

### SP Flash Tool process

1. Download SP Flash Tool for your OS
2. Obtain `scatter.txt` (partition layout file) for the specific device — this is device-specific and often found in firmware packages
3. Put device in Preloader Download Mode (power off, hold vol-down while connecting USB)
4. In SP Flash Tool:
   - Load the scatter.txt
   - Select "Download Only" mode
   - Check ONLY the Recovery partition entry
   - Set the image file to `recovery.img.signed`
   - Click Download

**Alternative**: Many MTK devices also support `fastboot` if you boot into fastbootd after using Magisk or an engineering unlock. Check whether `adb reboot bootloader` produces a device in `fastboot devices`.

---

## AVB Hash Footer and Re-signing

The toolchain handles AVB re-signing automatically using the AOSP test keys. Here is what happens internally:

1. `./gradlew unpack` reads the existing AVB footer from the stock image and saves it as `recovery.avb.json` (or `boot.avb.json`)
2. After ramdisk modifications, `./gradlew pack` recalculates the SHA256 hash of the new image content and re-appends the AVB hash footer using the test signing key from `aosp/security/testkey.pk8`
3. The resulting `*.signed` file has a valid (test-key) AVB hash footer

**For unlocked bootloaders**: The bootloader on an unlocked device displays an "orange state" warning but does NOT verify the signing key — it boots the image regardless. The test key is sufficient.

**For devices with custom AVB keys enrolled**: If someone previously enrolled a custom key via `fastboot flash avb_custom_key`, that key is checked even when unlocked. In practice, this is rare outside of developer scenarios. If encountered:
```bash
# Clear the custom key (reverts to accepting any signed image)
fastboot erase avb_custom_key
```

**Samsung-specific AVB**: Samsung adds a Samsung-specific signed hash (separate from standard AVB 2.0) that Odin verifies. When the OEM bootloader is unlocked, this Samsung-specific verification is disabled. The standard AOSP test key signing performed by `./gradlew pack` is sufficient.

---

## Image Header Versions and Compatibility

The boot image format has evolved across Android versions:

| Header Version | Android Version | Key Difference |
|----------------|-----------------|----------------|
| v0 | Android 8 and earlier | Basic: kernel + ramdisk + optional second stage |
| v1 | Android 9 | Added `recovery_dtbo` offset |
| v2 | Android 10 | Added `dtb` section — **used by reference device** |
| v3 | Android 12 (A/B GKI) | Vendor boot images, no embedded ramdisk in boot |
| v4 | Android 13 (VAB) | init_boot split, vendor ramdisk multipage |

The `./gradlew unpack` / `./gradlew pack` toolchain supports all header versions. The `recovery.json` (or `boot.json`) extracted by unpack records the header version; repacking uses the same version automatically.

When porting to a device with a different header version than the reference (v2):
- The unpack/pack cycle works transparently
- The metadata JSON will have a different `headerVersion` field
- No manual intervention needed — the toolchain reads and writes the correct version
