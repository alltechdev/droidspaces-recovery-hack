# Documentation Index

This directory contains comprehensive technical documentation for the droidspaces-recovery-hack-example project — a modified Samsung recovery image (MT6835) that boots an Ubuntu 24.04 container using the Droidspaces container runtime.

---

## Documents

### [overview.md](overview.md)
**Start here.** Project summary, target hardware (Samsung MT6835), high-level description of all changes made, repository layout, and the build workflow.

### [commit-history.md](commit-history.md)
**Full technical breakdown of every commit** in chronological order (oldest first). Each commit entry explains what changed, what files were added/modified/deleted, and why. Includes code diffs and detailed explanations of each decision.

### [architecture.md](architecture.md)
**System architecture documentation.** Boot sequence diagram, component map, SELinux security model, USB architecture, Wi-Fi initialization flow, and kernel module layout.

### [init-system.md](init-system.md)
**Complete reference for every `.rc` file** in the modified ramdisk. Documents each service, property trigger, and init stage. Covers `init.rc`, `init.recovery.usb.rc`, `init.touch.rc`, `init.mtk.wlan.rc`, and `init.ubuntu-droidspaces.example.rc`.

### [security-model.md](security-model.md)
**Security changes documentation.** Covers the two-layer SELinux bypass (policy patch + runtime disable), ADB root configuration, property-level security bypass, and Samsung DSMS removal. Includes a full security posture summary table.

### [droidspaces-container.md](droidspaces-container.md)
**Container runtime documentation.** `droidspaces` binary flags, `boot-ubuntu.sh` design, `recovery-console` interaction, rootfs configuration options, bind mount setup, hardware access model, activation instructions, and kernel requirements.

### [hardware-drivers.md](hardware-drivers.md)
**Wi-Fi and touchscreen driver documentation.** MTK gen4m Wi-Fi driver stack, WMT firmware, `wlan_init.sh` script, all firmware files, NVRAM calibration, FocalTech FT3419U touch driver, module dependencies, exported symbols, and how both interact with the container.

### [build-system.md](build-system.md)
**Build toolchain documentation.** Gradle tasks (`unpack`, `pack`, `clear`, `pull`, `flash`), image metadata files (`recovery.json`, `recovery.avb.json`), signing infrastructure, AOSP tools, `.gitignore` rationale, and CI configuration.

---

## Quick Reference

### Boot flow summary

```
Bootloader → Custom kernel (5.15.148) → init
  → SELinux disabled (on init)
  → adbd starts as root (post-fs-data)
  → Touch driver loaded (boot)
  → WLAN driver loaded → wlan0 up (boot)
  → droidspacesd daemon starts (boot)
  → Ubuntu 24.04 container launches (when droidspacesd=running)
```

### Key files

| File | Purpose |
|------|---------|
| `build/unzip_boot/kernel` | Custom kernel (Droidspaces-compatible) |
| `build/unzip_boot/root/system/bin/droidspaces` | Container runtime binary |
| `build/unzip_boot/root/system/bin/recovery-console` | Display server |
| `build/unzip_boot/root/system/bin/boot-ubuntu.sh` | Ubuntu launch script |
| `build/unzip_boot/root/system/bin/selinux-permissive` | SELinux disable script |
| `build/unzip_boot/root/system/etc/init/hw/init.rc` | Primary init script |
| `build/unzip_boot/root/system/etc/init/init.recovery.usb.rc` | USB ADB/fastboot setup |
| `build/unzip_boot/root/system/etc/init/init.ubuntu-droidspaces.example.rc` | Container auto-boot |
| `build/unzip_boot/root/sepolicy` | Patched SELinux policy |
| `build/unzip_boot/root/prop.default` | System properties (ro.secure=0, etc.) |

### To activate Ubuntu auto-boot

1. Rename `init.ubuntu-droidspaces.example.rc` → `init.ubuntu-droidspaces.rc`
2. Edit `boot-ubuntu.sh` to set `ROOTFS_PATH` to your Ubuntu rootfs location
3. Run `./gradlew pack`
4. Flash `recovery.img.signed`
