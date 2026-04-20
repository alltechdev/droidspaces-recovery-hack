# Droidspaces Container Runtime

## What is Droidspaces?

Droidspaces is a container runtime designed to run Linux distributions (specifically Ubuntu 24.04) on Android hardware using the recovery partition as a host environment. It leverages Linux namespaces, cgroups, and the device's actual hardware to provide a full Linux desktop/server environment without modifying the main Android system.

The recovery partition is used as the host because:
1. It boots independently of Android — the device can run the container without Android at all
2. It has a simpler init system that's easier to customize
3. It doesn't require any modifications to the main Android system partition
4. It can access all hardware directly without Android's HAL layer in the way

## Components Added to Recovery

### `/system/bin/droidspaces` (330 KiB pre-built ARM64 binary)

The container runtime binary. It has two primary modes:

**Daemon mode:**
```sh
droidspaces daemon --foreground
```
Starts the Droidspaces daemon. This initializes the runtime socket and keeps the container management subsystem running. The `--foreground` flag keeps it attached to the terminal (and to init's process group) rather than daemonizing.

**Container start mode:**
```sh
droidspaces -i <rootfs_path> -n <name> -h <hostname> [flags] start
```

| Flag | Type | Description |
|------|------|-------------|
| `-i <path>` | Required | Image-backed rootfs. Accepts `.img` files or raw block devices (e.g., `/dev/block/mmcblk0p1`) |
| `-r <path>` | Alternative to `-i` | Directory-backed rootfs (e.g., `/data/ubuntu/`) |
| `-n <name>` | Optional | Display name of the container (shown in recovery-console UI) |
| `-h <hostname>` | Optional | Hostname inside the container |
| `--hw-access` | Flag | Grants the container direct hardware access |
| `--privileged=full` | Flag | Full privilege mode — all Linux capabilities granted |
| `-B <host>:<guest>` | Bind mount | Bind-mount a host path into the container |
| `--foreground` | Flag | Don't daemonize; stay in foreground |

### `/system/bin/boot-ubuntu.sh`

The launcher script for the Ubuntu 24.04 container. It ties together `recovery-console` and `droidspaces`.

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

**Key design decisions:**

- **`exec`** — replaces the shell process with `recovery-console`, so `boot-ubuntu.sh` itself doesn't linger as a zombie parent
- **`recovery-console --exec "..."`** — `recovery-console` spawns the droidspaces process and routes its stdout/stderr to the device display. This is the mechanism that makes container output visible on screen.
- **`/dev/block/mmcblk0p1`** — the default rootfs path. This is a raw block device path; change it to any `.img` file path or other block device depending on where the Ubuntu rootfs is stored.
- **`-B /tmp:/recovery`** — the recovery environment's `/tmp` directory is bind-mounted into the container at `/recovery`. This allows file exchange between the host recovery and the Ubuntu container.
- **`--hw-access`** — grants the container access to hardware devices, necessary for display, GPU, audio, etc.
- **`--privileged=full`** — all Linux capabilities are available inside the container. Required for the container to manage its own networking, mount filesystems, load kernel modules, etc.

### `/system/bin/recovery-console` (pre-built ARM64 binary)

A display server and output wrapper for the recovery environment. It has two modes:

**Bare mode (no `--exec`):**
Renders output on the device display. What is displayed in bare mode is not documented — it is not exercised by the default configuration in this project.

**Wrapper mode (`--exec "<command>"`):**
Executes the command string, captures its stdout/stderr, and renders the output on the device display. This is how the Ubuntu container's console output appears on screen during boot.

### `/system/etc/init/init.ubuntu-droidspaces.example.rc`

The init script that auto-launches the container on boot. Named with `.example` to indicate it needs to be activated manually (see Activation section below).

```rc
service droidspacesd /system/bin/droidspaces daemon --foreground
    user root
    group root
    disabled
    seclabel u:r:recovery:s0

service ubuntu-droidspaces /system/bin/sh /system/bin/boot-ubuntu.sh
    user root
    group root
    oneshot
    disabled
    seclabel u:r:recovery:s0

on boot
    start droidspacesd

on property:init.svc.droidspacesd=running
    start ubuntu-droidspaces
```

**Startup sequencing**: The property trigger `init.svc.droidspacesd=running` is set by Android init when `droidspacesd` transitions from `starting` to `running` state. This guarantees the container is only launched after the Droidspaces daemon has fully initialized its runtime socket — not just started. This prevents a race condition where the container tries to connect to the daemon before it's ready.

---

## Rootfs Configuration

### Default: block device (`/dev/block/mmcblk0p1`)

The default configuration reads the Ubuntu rootfs from the first partition of the `mmcblk0` block device. The exact hardware this corresponds to (internal eMMC, SD card slot, etc.) depends on the specific device's storage layout.

```
/dev/block/mmcblk0p1  →  Ubuntu 24.04 rootfs image (partition or .img)
```

### Alternative: Directory-based rootfs

Edit `boot-ubuntu.sh` and change:
```sh
exec ${RECOVERY_CONSOLE_PATH} \
    --exec "${DROIDSPACES_BINARY_PATH} -i ${ROOTFS_PATH} ...start"
```
to:
```sh
exec ${RECOVERY_CONSOLE_PATH} \
    --exec "${DROIDSPACES_BINARY_PATH} -r /path/to/ubuntu/dir ...start"
```

### Alternative: `.img` file

Point `ROOTFS_PATH` to any accessible `.img` file path:
```sh
ROOTFS_PATH=/data/ubuntu24.img
```

---

## Bind Mounts

The default configuration uses one bind mount:

```
-B /tmp:/recovery
```

This bind-mounts the host recovery's `/tmp` filesystem into the Ubuntu container at `/recovery`. Since `/tmp` is a `tmpfs` on the host, this provides a shared memory-backed filesystem between the host and container. Useful for:
- Passing files between the recovery environment and Ubuntu
- Wi-Fi initialization logs (written to `/tmp/wlan-logs.txt` by `wlan_init.sh`)
- Any inter-environment communication

Additional bind mounts can be added to `DS_FLAGS` using additional `-B <host>:<guest>` arguments.

---

## Hardware Access Model

With `--hw-access` and `--privileged=full`, the container has direct access to:

- **Display**: The device display subsystem (via `recovery-console` as the display proxy)
- **GPU**: If the Droidspaces runtime exposes GPU devices to the container
- **USB**: The USB subsystem is available inside the container
- **Storage**: All block devices accessible in the recovery are accessible in the container
- **Network**: Wi-Fi via `wlan0` (brought up before container launch by `init.mtk.wlan.rc`)
- **Touchscreen**: `/dev/input/event8` (FocalTech FT3419U, loaded by `init.touch.rc`)
- **All `/dev` entries** that the container runtime chooses to expose

---

## Activation

The `.example.rc` file is not loaded by init automatically because Android's init imports `.rc` files by exact name. To activate container auto-boot:

### Option 1: Rename the example file
In `build/unzip_boot/root/system/etc/init/`:
```
init.ubuntu-droidspaces.example.rc  →  init.ubuntu-droidspaces.rc
```
Android init will discover and parse any `.rc` file in `/system/etc/init/`.

### Option 2: Add explicit import
Add to `init.rc`:
```rc
import /system/etc/init/init.ubuntu-droidspaces.example.rc
```

### Step 2: Set your rootfs path

Edit `build/unzip_boot/root/system/bin/boot-ubuntu.sh`:
```sh
ROOTFS_PATH=/dev/block/mmcblk0p1   # ← change to your actual rootfs location
```

### Step 3: Repack and flash

```bash
./gradlew pack
fastboot flash recovery recovery.img.signed
```

---

## How `recovery-console` and `droidspaces` Interact

```
init
  └─ starts: ubuntu-droidspaces service
       └─ runs: /system/bin/sh /system/bin/boot-ubuntu.sh
            └─ exec: recovery-console --exec "droidspaces -i ... start"
                 │
                 ├─ recovery-console manages the device display
                 │
                 └─ spawns: droidspaces -i /dev/block/mmcblk0p1 ... start
                      │
                      ├─ mounts Ubuntu rootfs
                      ├─ sets up Linux namespaces (PID, mount, UTS, IPC, ...)
                      ├─ sets up cgroups
                      ├─ bind-mounts /tmp → /recovery
                      ├─ applies capability grants
                      └─ exec Ubuntu's /sbin/init or /bin/systemd
                           └─ Ubuntu 24.04 userspace boots
```

The process tree from Android init's perspective:
- `init` (PID 1)
  - `droidspacesd` — runtime daemon (long-running)
  - `ubuntu-droidspaces` service → spawns `boot-ubuntu.sh` → `recovery-console` → `droidspaces` (which becomes the container's PID 1 namespace init)

---

## Kernel Requirements

The `kernel_configs.txt` file in this repo was extracted from the **stock** recovery kernel (the kernel replacement commit did not update it). It shows the relevant kernel capabilities present in the stock kernel:

| Config | Value | Relevance |
|--------|-------|-----------|
| `CONFIG_NAMESPACES` | `y` | Linux namespace isolation |
| `CONFIG_UTS_NS` | `y` | Hostname isolation |
| `CONFIG_IPC_NS` | `y` | IPC isolation |
| `CONFIG_PID_NS` | `y` | PID namespace isolation |
| `CONFIG_NET_NS` | `y` | Network namespace isolation |
| `CONFIG_USER_NS` | `y` | User namespace (UID mapping) |
| `CONFIG_CGROUPS` | `y` | Resource limits for containers |
| `CONFIG_OVERLAY_FS` | `y` | Overlay filesystem (often used by containers) |
| `CONFIG_FUSE_FS` (via `virtiofs`) | `y` | Filesystem access |
| `CONFIG_BINDER_IPC` | `y` | Android binder (if running Android apps in container) |
| `CONFIG_DM_*` | `y` | Device mapper (dm-crypt, dm-verity) |

**Note**: The `kernel_configs.txt` in this repo was extracted from the stock recovery kernel (it was not updated when the kernel was replaced in commit `8a63a39`). It shows the stock kernel already had all the required options enabled. The exact reason the kernel was replaced is not documented in the commit. `droidspaces` v5.9.5 uses only standard Linux syscalls and has no SoC-specific kernel dependencies observed via string analysis.
