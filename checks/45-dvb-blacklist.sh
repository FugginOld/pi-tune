#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# The kernel DVB-T driver grabs RTL-SDR dongles before userspace can.
CHECK_ID="dvb-blacklist"
CHECK_TITLE="Blacklist DVB-T driver (RTL-SDR)"
CHECK_RISK="low"

check_detect() {
    [[ $SDR_TYPE == rtlsdr ]] || return 2
    grep -rqs 'dvb_usb_rtl28xxu' /etc/modprobe.d/ 2>/dev/null && return 0
    return 1
}

check_why() {
    echo "RTL dongle present and dvb_usb_rtl28xxu is not blacklisted — it will claim the device on boot."
}

check_apply() {
    write_drop_in /etc/modprobe.d/pi-tune-rtlsdr-blacklist.conf <<'EOF'
# pi-tune: keep the DVB-T stack away from the SDR dongle.
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
blacklist dvb_core
EOF
    if [[ $DRY_RUN -eq 0 ]] && lsmod | grep -q dvb_usb_rtl28xxu; then
        run modprobe -r dvb_usb_rtl28xxu || require_manual "Could not unload dvb_usb_rtl28xxu live; it will stay blacklisted after reboot."
    fi
    return 0
}

check_revert() { return 0; }
