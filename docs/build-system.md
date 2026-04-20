# Build System

## Overview

The project uses [Android_boot_image_editor](https://github.com/cfig/Android_boot_image_editor) — a Kotlin/Gradle-based tool for unpacking and repacking Android boot images. The tool handles:
- Parsing Android boot image headers (V1, V2, V3, V4)
- Extracting and recompressing ramdisks (LZ4, gzip, LZ4 legacy)
- Unpacking/repacking device-tree blobs (DTB/DTBO)
- Extracting/embedding kernel images
- Signing with AVB (Android Verified Boot) hash footers
- Re-signing with platform signing keys

---

## Requirements

Install before working on this project:

**Linux / WSL:**
```bash
sudo apt install git device-tree-compiler lz4 xz-utils zlib1g-dev \
  openjdk-17-jdk gcc g++ python3 python-is-python3 \
  p7zip-full android-sdk-libsparse-utils erofs-utils
```

**macOS:**
```bash
brew install lz4 xz dtc
```

**Windows (Chocolatey):**
```
choco install openssl dtc-msys2 zip vim
```

**JDK**: JDK 11 or later required. JDK 17 recommended.

---

## Gradle Tasks

All operations are invoked via the Gradle wrapper:

### `./gradlew unpack`

Unpacks an Android image file (default: `recovery.img`) into `build/unzip_boot/`. The extracted content:

```
build/unzip_boot/
├── recovery.json           # Boot image header parameters
├── recovery.avb.json       # AVB footer metadata
├── kernel                  # Raw kernel image
├── dtb                     # Device tree blob
├── recoveryDtbo            # Recovery DTBO (if present)
├── ramdisk.img             # Unpacked ramdisk (after extraction)
├── ramdisk.img.lz4         # LZ4-compressed ramdisk
├── ramdisk.img_filelist.txt # List of files in ramdisk
├── kernel_version.txt      # Kernel version string
├── kernel_configs.txt      # Extracted kernel .config (if embedded)
└── root/                   # Ramdisk filesystem
```

The stock `recovery.img` was unpacked once (commit `c0d6760`) and the result committed. All subsequent changes are made directly to the files in `build/unzip_boot/`.

### `./gradlew pack`

Repacks `build/unzip_boot/` back into a flashable image. Output files:

| File | Description |
|------|-------------|
| `recovery.img.signed` | Final flashable image with AVB hash footer |
| `recovery.img.clear` | Intermediate: packed but not signed |
| `recovery.img.google` | Intermediate: Google-signed version (if applicable) |

The `recovery.img.signed` file is what gets flashed to the device.

### `./gradlew clear`

Cleans the workspace — removes all files in `build/unzip_boot/` and intermediate images. Run this between working on different image types.

### `./gradlew pull`

Pulls device tree blob from a rooted device via ADB (requires `adb root` on the host):
```bash
touch fake.dtb
./gradlew pull
```
Copies `dtc` to the device, dumps `/proc/device-tree`, and saves the DTB and decompiled DTS locally.

### `./gradlew flash`

Flashes the repacked image to a connected device via ADB. Requires the host to be connected to the device with `adb root` already working.

### `./gradlew check`

Runs unit tests for the boot image editor tool itself.

---

## Image Metadata Files

### `build/unzip_boot/recovery.json`

Boot image header metadata. The tool uses this to reconstruct the image header when repacking. Contains:
- Header version
- Kernel offset, size, compression
- Ramdisk offset, size, compression (LZ4)
- DTB size
- Board name, command line
- Page size

### `build/unzip_boot/recovery.avb.json`

AVB (Android Verified Boot) metadata. Contains:
- Hash algorithm (SHA256)
- Digest of the image
- Salt value
- Rollback index
- Flags
- Algorithm (SHA256_RSA4096 or similar)

The tool uses this to regenerate a valid AVB hash footer when repacking. The signing keys are in `aosp/security/`.

---

## Signing Infrastructure

Located in `aosp/security/`:

| File | Purpose |
|------|---------|
| `testkey.pk8` / `testkey.x509.pem` | AOSP test signing key (RSA 2048) |
| `platform.pk8` / `platform.x509.pem` | Platform signing key |
| `media.pk8` / `media.x509.pem` | Media signing key |
| `shared.pk8` / `shared.x509.pem` | Shared signing key |
| `verity.pk8` / `verity.x509.pem` | dm-verity signing key |
| `verity_key` | Verity key binary (embedded in kernel) |

The `aosp/avb/` directory contains `avbtool.py` (versions 1.1 and 1.2) with an applied patch (`avbtool.diff`) for compatibility.

The `aosp/make/target/product/gsi/testkey_rsa2048.pem` is the GSI (Generic System Image) signing key.

---

## Tools Directory

`tools/` contains miscellaneous helper scripts:

| File | Purpose |
|------|---------|
| `port.mk` | Makefile for porting operations |
| `release.mk` | Makefile for release builds |
| `syncCode.sh` | Script to sync code changes |
| `pull.py` | Python script for pulling device files |
| `factory_image_parser.py` | Parses Android factory image archives |
| `free.py` | Utility script |
| `debug.kts` | Kotlin script for debugging |
| `avb_print_property_desc.diff` | Patch for avbtool to print property descriptors |
| `extract_kernel.py.diff` | Patch for AOSP's extract_kernel.py |
| `mkdtboimg.diff` | Patch for mkdtboimg |
| `remove_projects.diff` | Patch to remove projects from repo manifest |
| `work_from_China.diff` | Patches for China mirror compatibility |
| `temp.txt` | Temporary notes |
| `bin/dtc-android` | Pre-built device tree compiler for Android |
| `bin/lz4.exe` | Pre-built LZ4 for Windows |
| `abe` | Shell script wrapper for Android_boot_image_editor |

---

## AOSP Tools

Located in `aosp/`:

### `aosp/avb/` — Android Verified Boot tools

- `avbtool.v1.1.py` / `avbtool.v1.2.py` — AVB signing and verification tool
- `avbtool.diff` — patch applied to avbtool
- `data/testkey_*.pem` / `.pk8` — RSA 2048/4096/8192 test keys for AVB signing
- `test/vts-testcase/security/avb/data/` — GSI AVB public keys for different Android versions (Q, R, S, T, and Automotive)

### `aosp/system/tools/mkbootimg/` — Boot image packing tool

- `mkbootimg.py` — AOSP mkbootimg Python script
- `gki/` — GKI (Generic Kernel Image) signing tools:
  - `certify_bootimg.py` — adds GKI boot image certificate
  - `generate_gki_certificate.py` — generates GKI certificate
  - `boot_signature_info.sh` — displays GKI signature info
  - `testdata/` — RSA 2048/4096 test keys for GKI signing

### `aosp/system/libufdt/utils/src/mkdtboimg.py`

Tool for creating and manipulating DTBO (Device Tree Blob Overlay) images.

### `aosp/system/extras/`

- `ext4_utils/mkuserimg_mke2fs.py` — Creates ext4 filesystem images
- `ext4_utils/mke2fs.conf` — mke2fs configuration
- `f2fs_utils/` — F2FS filesystem utilities

### `aosp/make/tools/extract_kernel.py`

Extracts kernel version and configuration from a compressed kernel image.

### `aosp/plugged/` — Pre-built binaries

Pre-built versions of AOSP tools for the host machine:
- `bin/e2fsdroid` — ext4 filesystem tool
- `bin/fec` — Forward Error Correction tool for dm-verity
- `bin/mkfs.erofs` — EROFS filesystem maker
- `bin/sefcontext_compile` — Compiles SELinux file contexts
- `lib/libc++.so` — C++ standard library
- `res/file_contexts.concat` — Concatenated file contexts

### `aosp/libxbc/` — Extended Boot Config library

- `libxbc.c` / `libxbc.h` — Library for reading/writing Android boot config
- `main.cpp` — CLI wrapper
- `meson.build` — Meson build system file

### `aosp/dispol/` — Display policy tool

- `Makefile`, `README.md` — Build and documentation for display policy tool

### `aosp/dracut/`

- `skipcpio.c` — Utility for skipping CPIO headers
- `README.md`

---

## .gitignore

Files excluded from version control:

```
.idea              # IDE project files
.gradle            # Gradle cache
build/             # Most build outputs (but build/unzip_boot/ is tracked)
__pycache__        # Python cache

# Added in commit df2296c:
build/unzip_boot/ramdisk.img       # Generated ramdisk (not source)
build/unzip_boot/ramdisk.img.lz4   # Compressed ramdisk (not source)
recovery.img.clear                  # Intermediate signed image
recovery.img.google                 # Intermediate Google-signed image
recovery.img.signed                 # Final output (don't commit the output)
uiderrors                           # UID error log from repacking
```

Note: `build/unzip_boot/` itself is **tracked** (not ignored), so all the ramdisk files, kernel, DTB, and init scripts are version-controlled. Only the generated/compressed forms of the ramdisk are excluded.

---

## .gitmodules

Three integration-test submodules are registered (part of the upstream boot image editor):

```
[submodule "src/integrationTest/resources"]
    path = src/integrationTest/resources
    url = https://github.com/cfig/android_image_res

[submodule "src/integrationTest/resources_2"]
    path = src/integrationTest/resources_2
    url = https://github.com/cfig/android_image_res2.git

[submodule "src/integrationTest/resources_3"]
    path = src/integrationTest/resources_3
    url = https://github.com/cfig/android_image_res3.git
```

These are only needed for running the integration tests (`./integrationTest.py`), not for packing/unpacking the recovery image.

---

## CI Configuration (`.travis.yml`)

The upstream boot image editor's Travis CI configuration:

```yaml
language: java
os: [linux, osx]
dist: focal
osx_image: xcode12.2
addons:
  apt:
    packages:
      - xz-utils
      - libblkid-dev
      - liblz4-tool
      - device-tree-compiler
      - python3
      - python-all
before_install:
  - if [ "$TRAVIS_OS_NAME" = "osx" ]; then brew update; fi
  - if [ "$TRAVIS_OS_NAME" = "osx" ]; then brew install lz4 dtc gradle; fi
script:
  - ./gradlew check
  - ./gradlew clean
  - ./integrationTest.py
```

This CI config is from the upstream tool and tests the tool itself, not the recovery image modifications.

---

## Kernel Configuration

The full kernel configuration is preserved in `build/unzip_boot/kernel_configs.txt` (8249 lines). Key facts:

- **Version**: Linux 5.15.148 ARM64
- **Compiler**: `Android (8508608, based on r450784e) clang version 14.0.7`
- **Linker**: LLVM LLD
- **Build tool**: Pahole 1.19

The configuration is automatically extracted from the kernel image's embedded config section by `aosp/make/tools/extract_kernel.py` during the `unpack` task.
