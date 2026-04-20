# Architecture

## Boot Sequence

The modified recovery image follows this startup sequence when flashed and booted:

```
Power on
  └─ Bootloader (Samsung BL)
       └─ Loads recovery.img → kernel + ramdisk
            └─ kernel (custom, 5.15.148) boots
                 └─ /system/bin/init starts
                      │
                      ├─ [early-init]
                      │    └─ ueventd starts (hotplug events)
                      │    └─ setprop sys.usb.configfs 1
                      │
                      ├─ [init]
                      │    └─ start selinux-permissive → echo 0 > /sys/fs/selinux/enforce
                      │    └─ export ENV=/system/etc/environment  (PS1 prompt)
                      │    └─ servicemanager starts
                      │
                      ├─ [late-init → fs → post-fs → post-fs-data]
                      │    └─ init.recovery.usb.rc: ConfigFS gadget setup
                      │    └─ setprop sys.usb.config adb → adbd starts (root shell)
                      │
                      ├─ [early-boot]
                      │    └─ setprop vendor.connsys.driver.ready no
                      │
                      └─ [boot]
                           ├─ init.touch.rc: start focaltech-tp (modprobe touch modules)
                           ├─ init.mtk.wlan.rc: mount /nvdata, start load_wlan_driver
                           │    └─ on load_wlan_driver stopped → start wifi-helper (wlan_init.sh)
                           └─ [if init.ubuntu-droidspaces.rc is present — see droidspaces-container.md]
                                init.ubuntu-droidspaces.rc: start droidspacesd
                                └─ on droidspacesd=running → start ubuntu-droidspaces
                                     └─ boot-ubuntu.sh:
                                          exec recovery-console --exec \
                                            "droidspaces -i /dev/block/mmcblk0p1 ... start"
```

## Component Map

```
┌─────────────────────────────────────────────────────────────────────┐
│  Android init (PID 1)                                               │
│  Reads: init.rc, init.recovery.usb.rc, init.touch.rc,              │
│         init.mtk.wlan.rc                                            │
│         (init.ubuntu-droidspaces.rc if renamed from .example.rc)    │
│                                                                     │
│  ┌────────────────────┐  ┌─────────────────────────────────────┐   │
│  │  selinux-permissive│  │  adbd (root, --root_seclabel=su)    │   │
│  │  oneshot           │  │  USB ADB daemon → root shell         │   │
│  └────────────────────┘  └─────────────────────────────────────┘   │
│                                                                     │
│  ┌────────────────────┐  ┌─────────────────────────────────────┐   │
│  │  focaltech-tp      │  │  load_wlan_driver                   │   │
│  │  modprobe:         │  │  modprobe wlan_drv_gen4m_6835.ko    │   │
│  │  sec_cmd.ko        │  │  → wifi-helper (wlan_init.sh)        │   │
│  │  tuihw-inf.ko      │  │    wmt_loader → wmt_launcher         │   │
│  │  focaltech_tp.ko   │  │    → wlan0 up                        │   │
│  │  → /dev/input/event8│  └─────────────────────────────────────┘   │
│  └────────────────────┘                                             │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  droidspacesd   (/system/bin/droidspaces daemon)           │    │
│  │  Container runtime daemon — manages runtime socket          │    │
│  │                                                             │    │
│  │  On running → ubuntu-droidspaces service starts             │    │
│  │                                                             │    │
│  │  ┌──────────────────────────────────────────────────────┐  │    │
│  │  │  recovery-console --exec "droidspaces -i ... start"  │  │    │
│  │  │                                                      │  │    │
│  │  │  ┌─────────────────────────────────────────────┐    │  │    │
│  │  │  │  droidspaces container process              │    │  │    │
│  │  │  │  Rootfs: /dev/block/mmcblk0p1               │    │  │    │
│  │  │  │  Ubuntu 24.04 userland                      │    │  │    │
│  │  │  │  Bind: /tmp → /recovery inside container    │    │  │    │
│  │  │  └─────────────────────────────────────────────┘    │  │    │
│  │  │                                                      │  │    │
│  │  │  Display output → device screen                      │  │    │
│  │  └──────────────────────────────────────────────────────┘  │    │
│  └────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

## SELinux Security Model

The project uses a two-layer approach to disable SELinux enforcement:

### Layer 1: Policy binary patch (magiskpolicy)

The precompiled `sepolicy` binary was patched at build time using magiskpolicy:
- `adbd` domain: allowed to set its own security context and transition to `su`
- `adbd`, `su`, `recovery` domains: marked **permissive** in the policy itself

This means even if the runtime enforcement flag is `1`, these three domains will only audit (log) denials rather than block them.

### Layer 2: Runtime selinux-permissive service

At the `on init` trigger, `selinux-permissive` writes `0` to `/sys/fs/selinux/enforce`. This switches the **entire kernel** to permissive mode globally — not just specific domains. All SELinux denials system-wide are logged but not enforced. This fires before `fs`, `post-fs`, `early-boot`, and `boot`, so SELinux is permissive before hardware drivers and mounts initialize.

### Property-level security bypass

In `prop.default`:
- `ro.secure=0` — disables security restrictions
- `ro.adb.secure=0` — disables ADB authentication requirement
- `ro.debuggable=1` — enables debug features
- `service.adb.root=1` — instructs adbd to run as root on start
- `ro.force.debuggable=1` — additional debuggable flag

## USB Architecture

The USB subsystem uses Linux USB ConfigFS (kernel 3.11+) because `sys.usb.configfs=1` is set at `early-init`.

```
ConfigFS gadget at /config/usb_gadget/g1
  ├── idVendor: 0x18D1 (Google)
  ├── strings/0x409/
  │    ├── serialnumber → ${ro.serialno}
  │    ├── manufacturer → ${ro.product.manufacturer}
  │    └── product → ${ro.product.model}
  ├── functions/
  │    ├── ffs.adb      (FunctionFS for ADB)
  │    ├── ffs.fastboot (FunctionFS for fastboot)
  │    └── ss_mon.etc   (Samsung USB function — purpose unknown from source alone)
  └── configs/b.1/
       ├── MaxPower: 900mA
       ├── strings/0x409/configuration → "adb" or "fastboot"
       ├── f1 → symlink to active function
       └── f2 → symlink to ss_mon.etc

FunctionFS mounts:
  /dev/usb-ffs/adb      (uid=2000/gid=2000 → shell)
  /dev/usb-ffs/fastboot (rmode=0770,fmode=0660,uid=1000/gid=1000 → system)
```

USB Product IDs:
- ADB mode: `0xD001`
- Fastboot mode: `0x4EE0`

## Wi-Fi Initialization Flow

```
[early-boot]
  setprop vendor.connsys.driver.ready no

[boot]
  mkdir /nvdata && mount ext4 /dev/block/sdc28 /nvdata wait noatime
  write firmware path: /vendor/firmware,/nvdata/APCFG/APRDEB,/efs/wifi
  start load_wlan_driver
    └─ modprobe wlan_drv_gen4m_6835.ko nvram=WIFI
         (reads NVRAM cal from /nvdata/APCFG/APRDEB)

[when load_wlan_driver stops]
  start wifi-helper → wlan_init.sh:
    1. /vendor/bin/wmt_loader      (firmware patch into MT6631 chip)
    2. /vendor/bin/wmt_launcher &  (WMT daemon: co-existence management)
    3. poll vendor.connsys.driver.ready == "yes"
    4. echo 1 > /dev/wmtWifi       (power on Wi-Fi subsystem)
    5. ifconfig wlan0 up            (interface up)
```

## Kernel Module Layout

The ramdisk carries two separate module directories:

### `/lib/modules/` (system — loaded by modprobe via `modules.load.recovery` during init)

~100 modules covering:
- MediaTek MT6835 clocks (25+ clk-mt6835-*.ko)
- Display: `mediatek-drm.ko`, `mtk_panel_ext.ko`, `mcd-panel.ko`, panel drivers
- Storage: `mtk-mmc-mod.ko`, `ufs-mediatek-mod.ko`, `cqhci.ko`
- USB: `mtu3.ko`, `xhci-mtk-hcd-v2.ko`, `usb_f_conn_gadget.ko`
- Power: `mt6375.ko`, `mt6377-*.ko`, `mtk_charger_framework.ko`, charging algorithms
- Sensors: `hf_manager.ko`, `sensors_class.ko`, `hx9036.ko`
- Security: `tzdev.ko`, `teeperf.ko`, `rpmb.ko`
- Compression: `zram.ko`, `zsmalloc.ko`

### `/vendor/lib/modules/` (touch subsystem)

- `sec_cmd.ko` — Samsung command interface
- `tuihw-inf.ko` — Trusted UI hardware interface
- `focaltech_tp.ko` — FocalTech FT3419U touchscreen driver

### `/vendor/wlan_modules/lib/modules/` (Wi-Fi + BT + modem)

- `wlan_drv_gen4m_6835.ko` — Main Wi-Fi driver
- `wmt_drv.ko`, `wmt_chrdev_wifi.ko` — WMT management
- `bt_drv_connac1x.ko`, `btif_drv.ko` — Bluetooth
- `connadp.ko`, `mddp.ko`, `rps_perf.ko` — Connectivity adaptation
- CCCI stack (`ccci_md_all.ko`, etc.) — Cellular modem interface
- MTK power management support modules
