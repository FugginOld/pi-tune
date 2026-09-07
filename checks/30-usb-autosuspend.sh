#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# USB autosuspend drops samples on SDR dongles. Disable it globally when an
# SDR is present.
CHECK_ID="usb-autosuspend"
CHECK_TITLE="Disable USB autosuspend (SDR stability)"
CHECK_RISK="medium"

check_detect() {
    [[ $HAS_SDR -eq 1 ]] || return 2
    cmdline_has "usbcore.autosuspend=-1" && return 0
    grep -rqs 'usbcore.*autosuspend=-1' /etc/modprobe.d/ 2>/dev/null && return 0
    local cur=""
    [[ -r /sys/module/usbcore/parameters/autosuspend ]] && cur=$(cat /sys/module/usbcore/parameters/autosuspend)
    [[ $cur == "-1" ]] && return 0
    return 1
}

check_why() {
    echo "${SDR_TYPE:-SDR} attached and USB autosuspend is active — the hub can idle the port mid-capture."
}

check_apply() {
    if [[ -n ${CMDLINE_TXT:-} ]]; then
        cmdline_add "usbcore.autosuspend=-1" || return 1
    else
        write_drop_in /etc/modprobe.d/pi-tune-usb.conf <<'EOF'
# pi-tune: keep USB devices (SDR) out of autosuspend.
options usbcore autosuspend=-1
EOF
        require_manual "usbcore is often built into the kernel; if the setting does not stick after reboot, add usbcore.autosuspend=-1 to the kernel command line manually."
    fi

    # Take effect now where the kernel allows it.
    if [[ $DRY_RUN -eq 0 && -w /sys/module/usbcore/parameters/autosuspend ]]; then
        echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true
    fi
    return 0
}

check_revert() { return 0; }
