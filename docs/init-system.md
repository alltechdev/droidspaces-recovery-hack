# Init System Reference

This document covers every `.rc` file in the modified recovery ramdisk, what each one does, and what was changed from stock.

---

## `build/unzip_boot/root/system/etc/init/hw/init.rc`

The primary init script. This is the file Android's `init` process (PID 1) reads first.

### `early-init` trigger

```rc
on early-init
    restorecon /postinstall
    copy /system/etc/ld.config.txt /linkerconfig/ld.config.txt
    chmod 444 /linkerconfig/ld.config.txt
    start ueventd
    setprop sys.usb.configfs 1
    setprop persist.vendor.softdog off
```

**`sys.usb.configfs 1`** — Forces USB ConfigFS mode. This determines which USB gadget code path is used in `init.recovery.usb.rc`.

### `init` trigger (modified)

```rc
on init
    start selinux-permissive        ← ADDED: disable SELinux enforcement immediately

    export ANDROID_ROOT /system
    export ANDROID_DATA /data
    export EXTERNAL_STORAGE /sdcard
    export ENV /system/etc/environment  ← ADDED: shell prompt/environment file

    symlink /proc/self/fd/0 /dev/stdin
    symlink /proc/self/fd/1 /dev/stdout
    symlink /proc/self/fd/2 /dev/stderr
    symlink /system/bin /bin
    symlink /system/etc /etc

    mkdir /sdcard; mkdir /system; mkdir /data; mkdir /cache
    mkdir /sideload; mkdir /mnt/system
    mount tmpfs tmpfs /tmp

    write /proc/sys/kernel/panic_on_oops 1
    write /proc/sys/vm/max_map_count 1000000

    mkdir /dev/binderfs
    mount binder binder /dev/binderfs stats=global
    chmod 0755 /dev/binderfs
    symlink /dev/binderfs/binder /dev/binder
    chmod 0666 /dev/binderfs/binder

    start servicemanager
```

### `boot` trigger

```rc
on boot
    ifup lo
    hostname localhost
    domainname localdomain
    class_start default
    class_start hal
```

Starts all services in the `default` and `hal` classes.

### `late-init` trigger

```rc
on late-init
    trigger early-fs
    trigger fs
    trigger post-fs
    trigger post-fs-data
    trigger firmware_mounts_complete
    trigger early-boot
    trigger boot
```

This is the standard Android recovery init chain.

### Services (modified)

#### `ueventd` (unchanged)
```rc
service ueventd /system/bin/ueventd
    critical
    seclabel u:r:ueventd:s0
```

#### `charger` (unchanged)
```rc
service charger /system/bin/charger
    critical
    seclabel u:r:charger:s0
```

#### `recovery` (MODIFIED — disabled)
```rc
service recovery /system/bin/recovery
    socket recovery stream 422 system system
    seclabel u:r:recovery:s0
    disabled    ← ADDED: prevents Samsung recovery UI from auto-starting
```

#### `selinux-permissive` (ADDED)
```rc
service selinux-permissive /system/bin/selinux-permissive
    disabled
    oneshot
    user root
    group root
    seclabel u:r:recovery:s0
```

#### `recovery-console` (ADDED then commented out)
```rc
#service recovery-console /system/bin/recovery-console
#    disabled
#    oneshot
#    user root
#    group root
#    seclabel u:r:recovery:s0
#
#on boot
#    start recovery-console
```

Commented out in the final commit because `recovery-console` is now started as a child of `boot-ubuntu.sh` rather than directly by init.

### `post-fs-data` trigger (ADDED)

```rc
on post-fs-data
    setprop sys.usb.config adb
```

Triggers ADB mode on the USB gadget, which causes `adbd` to start.

---

## `build/unzip_boot/root/system/etc/init/init.recovery.usb.rc`

Created in commit `96dbf77`. Contains all USB ADB/fastboot gadget logic extracted from `init.rc`.

### Services

| Service | Binary | Notes |
|---------|--------|-------|
| `adbd` | `/system/bin/adbd --root_seclabel=u:r:su:s0 --device_banner=recovery` | ADB daemon. `--root_seclabel` means the shell session gets `su` SELinux context. `--device_banner=recovery` makes `adb devices` show "recovery" as the transport qualifier. |
| `fastbootd` | `/system/bin/fastbootd` | Fastboot daemon for flashing in recovery mode |

### Property triggers

| Trigger | Action |
|---------|--------|
| `service.adb.root=1` | `restart adbd` |
| `sys.usb.config=adb` | `start adbd` |
| `sys.usb.config=fastboot` | `start fastbootd` |
| `sys.usb.config=none && configfs=0` | Stop both, disable android_usb |
| `sys.usb.config=adb && configfs=0` | Product 0xD001, enable android_usb |
| `sys.usb.config=sideload && configfs=0` | Same as adb (0xD001) |
| `sys.usb.config=fastboot && configfs=0` | Product 0x4EE0, enable android_usb |
| `sys.usb.config=none && ffs.ready=1 && configfs=1` | Detach UDC, stop daemons |
| `sys.usb.config=sideload && ffs.ready=1 && configfs=1` | ADB gadget via configfs |
| `sys.usb.config=adb && ffs.ready=1 && configfs=1` | ADB gadget via configfs |
| `sys.usb.config=fastboot && ffs.ready=1 && configfs=1` | Fastboot gadget via configfs |

### ConfigFS setup (when `sys.usb.configfs=1`)

Runs at the `fs` trigger:
```
mount configfs none /config
mkdir /config/usb_gadget/g1
write /config/usb_gadget/g1/idVendor 0x18D1
mkdir /config/usb_gadget/g1/strings/0x409 0770
write serialnumber, manufacturer, product from properties
mkdir functions/ffs.adb, functions/ffs.fastboot, functions/ss_mon.etc
mkdir configs/b.1 0777 + configs/b.1/strings/0x409
write MaxPower 900
```

### FunctionFS mounts

```
mount functionfs adb /dev/usb-ffs/adb uid=2000,gid=2000
mount functionfs fastboot /dev/usb-ffs/fastboot rmode=0770,fmode=0660,uid=1000,gid=1000
```

---

## `build/unzip_boot/root/system/etc/init/init.touch.rc`

Created in commit `0458f9b`. Loads the FocalTech touchscreen driver.

```rc
service focaltech-tp /system/bin/modprobe -d /vendor/lib/modules \
        --all=/vendor/lib/modules/modules.load
    user root
    group root
    oneshot
    disabled
    seclabel u:r:recovery:s0

on boot
    write /sys/module/firmware_class/parameters/path \
          /vendor/firmware,/nvdata/APCFG/APRDEB,/efs/wifi
    start focaltech-tp
```

**`--all` flag**: loads all modules listed in `modules.load` (sec_cmd, tuihw-inf, focaltech_tp) in dependency order in a single modprobe invocation.

**Firmware path**: Sets the kernel's firmware loader search path so `focaltech_tp.ko` can find `focaltech_ts_fw_ft3419u.bin`.

---

## `build/unzip_boot/root/system/etc/init/init.mtk.wlan.rc`

Created in commit `209e6e0`. Manages Wi-Fi driver loading and interface bring-up.

```rc
on early-boot
    setprop vendor.connsys.driver.ready no

on boot
    mkdir /nvdata 0771 system system
    mount ext4 /dev/block/sdc28 /nvdata wait noatime
    write /sys/module/firmware_class/parameters/path \
          /vendor/firmware,/nvdata/APCFG/APRDEB,/efs/wifi
    start load_wlan_driver

service load_wlan_driver \
        /system/bin/modprobe -d /vendor/wlan_modules/lib/modules/ \
        wlan_drv_gen4m_6835.ko nvram=WIFI
    user root; group root; oneshot; disabled; seclabel u:r:recovery:s0

service wifi-helper /system/bin/sh /system/bin/wlan_init.sh
    user root; group root; oneshot; disabled; seclabel u:r:recovery:s0

on property:init.svc.load_wlan_driver=stopped
    start wifi-helper
```

**`nvram=WIFI`**: Tells the WLAN driver to read NVRAM calibration data. The driver looks in `/nvdata/APCFG/APRDEB/WIFI` for calibration.

**`/dev/block/sdc28`**: The nvdata partition. MediaTek devices typically use a dedicated nvdata partition for Wi-Fi calibration, IMEI, and other hardware parameters.

**Property trigger**: `init.svc.load_wlan_driver=stopped` fires when the oneshot service finishes (either success or failure). This ensures `wifi-helper` always runs after the kernel module is loaded.

---

## `build/unzip_boot/root/system/etc/init/init.ubuntu-droidspaces.example.rc`

Created in commit `45e7861`. The example init script for Ubuntu container auto-boot.

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

**Note**: The `.example` suffix means this file is **not automatically included** by the init system (init.rc `import` statements use exact names). To activate it, rename it to `init.ubuntu-droidspaces.rc` or add an explicit `import` statement.

**`droidspacesd`** does not have `oneshot` — it is a long-running daemon. If it crashes, init will restart it (default behavior for non-oneshot services).

**`ubuntu-droidspaces`** is `oneshot` — it runs once (launching the container), after which the container process itself keeps running.

---

## `build/unzip_boot/root/system/etc/init/init.recovery.mt6835.rc`

This is the stock MediaTek MT6835 recovery init file. It was present in the unpacked stock image and was not modified by this project.

---

## `build/unzip_boot/root/system/etc/init/init.recovery.samsung.rc`

Stock Samsung recovery init file. Imported at the top of `init.rc`:
```
import /init.recovery.samsung.rc
```

Not modified by this project.

---

## Property System Changes

### `prop.default` modifications

| Property | Stock | Modified | Effect |
|----------|-------|----------|--------|
| `ro.secure` | `1` | `0` | Disables security restrictions on `adbd` |
| `ro.adb.secure` | `1` | `0` | Disables ADB authentication (no RSA key prompt) |
| `ro.debuggable` | `0` | `1` | Enables debug mode |
| `service.adb.root` | _(unset)_ | `1` | `adbd` starts as root |
| `ro.force.debuggable` | _(unset)_ | `1` | Forces debug mode |

### `plat_property_contexts` addition

```
ro.force.debuggable u:object_r:build_prop:s0 exact bool
```

Required so the property namespace doesn't reject `ro.force.debuggable` as an unknown property (Android property contexts define which properties are valid).

---

## `build/unzip_boot/root/system/etc/environment`

```sh
#!/system/bin/sh
export PS1='$(whoami)@$(hostname):$PWD # '
```

Sourced by any `sh` process that inherits `$ENV=/system/etc/environment`. Produces:
```
root@localhost:/ #
```

The `$()` subshells in the PS1 value re-evaluate on every prompt redraw, so the username, hostname, and working directory update dynamically.
