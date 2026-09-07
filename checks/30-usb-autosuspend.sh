#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# USB autosuspend drops samples on SDR dongles, and stalls I/O on a box that
# boots from a USB-attached disk. Either is reason enough to disable it.
CHECK_ID="usb-autosuspend"
CHECK_TITLE="Disable USB autosuspend"
CHECK_RISK="medium"

check_detect() {
    # Root on USB matters as much as an SDR: an idled port under the root
    # filesystem stalls I/O to the boot device and can drop it off the bus.
    [[ $HAS_SDR -eq 1 || $ROOT_IS_USB -eq 1 ]] || return 2
    cmdline_has "usbcore.autosuspend=-1" && return 0
    grep -rqs 'usbcore.*autosuspend=-1' /etc/modprobe.d/ 2>/dev/null && return 0
    local cur=""
    [[ -r /sys/module/usbcore/parameters/autosuspend ]] && cur=$(cat /sys/module/usbcore/parameters/autosuspend)
    [[ $cur == "-1" ]] && return 0
    return 1
}

check_why() {
    # Both can be true on an ADS-B box that boots from USB. The root-filesystem
    # phrasing is the more serious of the two, so it wins.
    if [[ $ROOT_IS_USB -eq 1 ]]; then
        echo "Root filesystem is on a USB-attached disk and autosuspend is active — an idled port stalls I/O to the boot device."
    else
        echo "${SDR_TYPE:-SDR} attached and USB autosuspend is active — the hub can idle the port mid-capture."
    fi
}

check_impact() {
    cat <<EOF
Stops the kernel idling USB ports. Raises idle power slightly for every USB device on the board, not just the one that needs it. Applied via the kernel command line, so it needs a reboot to take effect.$(
    [[ $ROOT_IS_USB -eq 1 ]] && printf ' %s' \
        "With root on USB this protects the boot device: a port that idles under the root filesystem stalls I/O and can drop the disk off the bus entirely."
)
EOF
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
