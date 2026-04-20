#!/system/bin/sh
# init_wlan.sh - bring up wlan0 in recovery

# Redirect all stdout and stderr to the log file
exec > /tmp/wlan-logs.txt 2>&1

FW_PATH="/vendor/firmware"

log() { echo "[init_wlan] $1"; }
die() { log "FATAL: $1"; exit 1; }

# chip detection
log "starting wmt_loader..."
/vendor/bin/wmt_loader || log "WARN: wmt_loader exited non-zero"
sleep 1

# WMT init - patch ioctls + wmtd_thread, sets connsys.driver.ready=yes
log "starting wmt_launcher..."
/vendor/bin/wmt_launcher -p "$FW_PATH/" -o 1 &

log "waiting for connsys ready..."
for i in $(seq 1 20); do
    [ "$(getprop vendor.connsys.driver.ready)" = "yes" ] && break
    sleep 0.5
done

[ "$(getprop vendor.connsys.driver.ready)" != "yes" ] && log "WARN: connsys never ready, trying anyway"

log "powering on WiFi..."
echo 1 > /dev/wmtWifi

if ifconfig -a | grep -q "wlan0"; then
    ifconfig wlan0 up
    log "SUCCESS: wlan0 is up"
    ifconfig wlan0
else
    log "FAIL: wlan0 not found"
    dmesg | grep -iE "WMT|wlan|WIFI" | tail -20
    exit 1
fi
