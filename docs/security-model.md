# Security Model

This document explains every security-related change made to the recovery image and the reasoning behind each decision.

---

## Overview

The stock Samsung recovery image is locked down in multiple layers:
1. **SELinux enforcing** — all inter-process and filesystem access is mediated by the SELinux policy
2. **ADB authentication** — ADB requires RSA key authorization from the host
3. **No root ADB** — `adbd` runs as the `shell` user, not root
4. **No debuggable** — `ro.debuggable=0` disables many developer facilities
5. **Samsung DSMS** — Samsung telemetry/diagnostics daemon running in background

This project removes all five layers to create an environment where arbitrary code (the Ubuntu container) can run with full system privileges.

---

## Layer 1: SELinux Policy Binary Patch

### What was done

The precompiled `sepolicy` binary at `build/unzip_boot/root/sepolicy` was patched at development time using **magiskpolicy** (the policy patching tool from the Magisk root framework):

```bash
./magiskpolicy --load sepolicy --save sepolicy.patched '
allow adbd adbd process setcurrent
allow adbd su process dyntransition
permissive { adbd }
permissive { su }
permissive { recovery }
'
```

### What each rule adds

#### `allow adbd adbd process setcurrent`

Without this, the `adbd` process cannot change its own SELinux security context. With it, `adbd` can call `setcon()` to place itself into a different security context — specifically `u:r:su:s0` (the root shell context).

#### `allow adbd su process dyntransition`

Enables dynamic domain transition from `adbd` to `su`. A dynamic domain transition (as opposed to a type transition on exec) allows `adbd` to change its domain at runtime via `setcon()`. This is how `--root_seclabel=u:r:su:s0` in the `adbd` service definition takes effect.

#### `permissive { adbd }`

Places the `adbd` domain into **permissive mode**. SELinux will audit (log to dmesg) any access that would otherwise be denied, but it will not actually block the access. This catches cases where the policy patch missed a needed `allow` rule.

#### `permissive { su }`

Same for the `su` (root shell) domain. Without this, every operation performed in the root ADB shell that is not explicitly allowed in the policy would be blocked.

#### `permissive { recovery }`

The custom services added by this project (`selinux-permissive`, `recovery-console`, `droidspacesd`, `focaltech-tp`, `load_wlan_driver`, etc.) all run under `seclabel u:r:recovery:s0`. Making the `recovery` domain permissive means all of them can perform any operation without SELinux denial, even if the policy does not have an explicit `allow` rule.

### Why a policy patch instead of just setting permissive?

The policy patch ensures that even if the runtime permissive flag (layer 2) is blocked by AVB verification or fails to run, the critical domains still have working transitions and do not generate hard denials that kill the process.

---

## Layer 2: Runtime SELinux Disable (selinux-permissive)

### What was done

A two-line shell script was added:

**`/system/bin/selinux-permissive`:**
```sh
#!/system/bin/sh
echo 0 > /sys/fs/selinux/enforce
```

And it is started at the very first init trigger:

**In `init.rc`:**
```rc
on init
    start selinux-permissive
```

### Effect

Writing `0` to `/sys/fs/selinux/enforce` switches the **entire SELinux subsystem** to permissive mode globally. This is kernel-level — it affects all processes and all domains system-wide, not just the three domains patched in layer 1. After this runs, SELinux only logs denials; nothing is blocked.

### Why run it at `on init`?

The `on init` trigger fires before the filesystem mount stages (`early-fs`, `fs`, `post-fs`, `post-fs-data`) and before hardware initialization (`early-boot`, `boot`). Running `selinux-permissive` here ensures SELinux is disabled before any hardware services, filesystem mounts, or driver initialization begins. (Note: `ueventd` is started at `early-init`, but writing to `/sys/fs/selinux/enforce` requires selinuxfs to be available, which is reliably present by the `on init` stage.)

### Service definition

```rc
service selinux-permissive /system/bin/selinux-permissive
    disabled        ← must be explicitly started; not auto-started by class
    oneshot         ← exits after running; init does not restart it
    user root       ← must run as root to write to /sys/fs/selinux/enforce
    group root
    seclabel u:r:recovery:s0
```

---

## Layer 3: ADB Root Configuration

### Property changes in `prop.default`

```
ro.secure=0
ro.adb.secure=0
ro.debuggable=1
service.adb.root=1
ro.force.debuggable=1
```

#### `ro.secure=0`

This property is checked by multiple Android daemons. When `0`, `adbd` will not enforce that it runs as the `shell` user — it will accept root requests. Some security checks in other system code are also relaxed.

#### `ro.adb.secure=0`

Controls whether ADB requires RSA host key authorization. When `1`, connecting an unknown host triggers the "Allow USB debugging?" dialog and requires key approval. When `0`, any host can connect without authorization — no dialog, no key needed.

#### `ro.debuggable=1`

Marks the build as debuggable. This enables:
- `adb root` command (without this property being `1`, `adb root` fails even if the daemon supports it)
- Various debug sysctls and kernel parameters
- `ptrace` between arbitrary processes

#### `service.adb.root=1`

This property is explicitly checked by `adbd` at startup. When set, `adbd` starts running with UID 0 (root) rather than UID 2000 (shell). Combined with `--root_seclabel=u:r:su:s0` in the service definition, the ADB shell session runs as root in the `su` SELinux domain.

#### `ro.force.debuggable=1`

An additional debuggable flag checked by some Samsung-specific code paths.

### adbd service configuration

```rc
service adbd /system/bin/adbd --root_seclabel=u:r:su:s0 --device_banner=recovery
    disabled
    socket adbd stream 660 system system
    seclabel u:r:adbd:s0
```

`--root_seclabel=u:r:su:s0`: When `adbd` grants a root shell, it sets the SELinux context of the shell process to `u:r:su:s0` rather than the default `u:r:shell:s0`. This is the security context that has the broadest permissions (patched to permissive in layer 1).

### Property context for `ro.force.debuggable`

Added to `plat_property_contexts`:
```
ro.force.debuggable u:object_r:build_prop:s0 exact bool
```

Android's property service validates properties against the contexts file. Without this entry, setting `ro.force.debuggable` would be rejected.

---

## Samsung DSMS Removal

### What was removed

Samsung ships a proprietary daemon in the recovery image called **dsms** (likely "Device Security Monitoring Service"). The following were deleted:

| Component | Description |
|-----------|-------------|
| `/system/bin/dsms` | The daemon binary |
| `/system/etc/init/dsms.rc` | Sets up `/efs/dsms/` and `/data/local/dsms/` log directories |
| `/system/etc/init/dsms_common.rc` | Defines and starts the `dsmsd` service |

### Why removed

1. **Unknown behavior**: The purpose of this daemon is not documented in the `.rc` files. It has write access to system paths and runs at boot — potential for interference with custom services.
2. **UID 5031 / `vendor_dsms`**: It runs as a proprietary Samsung UID, not a standard Android UID. This suggests it has vendor-specific capabilities not available to ordinary processes.
3. **`/efs/` access**: DSMS creates log files in `/efs/dsms/`. The EFS partition on Samsung devices is generally used for device-specific calibration data. Write access to this partition is undesirable in a controlled recovery environment.
4. **Clutter**: It starts unnecessarily on every boot and wastes resources.

---

## Security Posture Summary

After all modifications, the recovery environment has:

| Security Control | State |
|-----------------|-------|
| SELinux enforcement | **Disabled** (runtime) |
| SELinux policy | **Permissive** for `adbd`, `su`, `recovery` domains |
| ADB authentication | **Disabled** (`ro.adb.secure=0`) |
| ADB root | **Enabled** (`service.adb.root=1`) |
| Debuggable mode | **Enabled** (`ro.debuggable=1`) |
| ro.secure | **0** (security restrictions off) |
| Samsung DSMS | **Removed** |
| Stock recovery UI | **Disabled** (service marked disabled) |

This is intentional — the recovery is designed to be a fully open, root-accessible Linux environment for running the Droidspaces Ubuntu container.
