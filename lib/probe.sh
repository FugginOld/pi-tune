#!/usr/bin/env bash
# shellcheck disable=SC2034  # probe globals are consumed by dynamically sourced check modules
# lib/probe.sh — fingerprint the host once, up front. Every check module reads
# these globals instead of re-detecting. Anything undetectable is left empty and
# modules are expected to treat empty as "skip", never as "assume".

probe_host() {
    # --- board ---------------------------------------------------------------
    PI_MODEL="unknown"
    if [[ -r /proc/device-tree/model ]]; then
        PI_MODEL=$(tr -d '\0' < /proc/device-tree/model)
    elif [[ -r /sys/firmware/devicetree/base/model ]]; then
        PI_MODEL=$(tr -d '\0' < /sys/firmware/devicetree/base/model)
    fi

    PI_GEN=""
    case "$PI_MODEL" in
        *"Raspberry Pi 5"*) PI_GEN=5 ;;
        *"Raspberry Pi 4"*) PI_GEN=4 ;;
        *"Raspberry Pi 3"*) PI_GEN=3 ;;
        *"Raspberry Pi 2"*) PI_GEN=2 ;;
        *"Raspberry Pi"*)   PI_GEN=1 ;;
    esac

    # --- distro --------------------------------------------------------------
    DISTRO_ID=""; DISTRO_PRETTY=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-}"
        DISTRO_PRETTY="${PRETTY_NAME:-}"
    fi
    IS_ARMBIAN=0
    [[ -r /etc/armbian-release ]] && IS_ARMBIAN=1

    # --- memory / arch -------------------------------------------------------
    RAM_MB=$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    PAGE_SIZE=$(getconf PAGESIZE 2>/dev/null || echo 4096)
    ARCH=$(uname -m)
    CPU_COUNT=$(nproc 2>/dev/null || echo 1)

    # --- firmware config location -------------------------------------------
    # Bookworm+ and current Armbian use /boot/firmware; older layouts use /boot.
    FIRMWARE_DIR=""; CONFIG_TXT=""; CMDLINE_TXT=""
    local d
    for d in /boot/firmware /boot; do
        if [[ -f "$d/config.txt" ]]; then
            FIRMWARE_DIR="$d"
            CONFIG_TXT="$d/config.txt"
            [[ -f "$d/cmdline.txt" ]] && CMDLINE_TXT="$d/cmdline.txt"
            break
        fi
    done
    # Armbian layers its own env file over the firmware config on some images:
    # anything a check writes to config.txt can be overridden from here, so a
    # check that touches boot config must look at both.
    ARMBIAN_ENV=""
    [[ -f /boot/armbianEnv.txt ]] && ARMBIAN_ENV=/boot/armbianEnv.txt

    # --- root storage --------------------------------------------------------
    ROOT_SRC=""; ROOT_FSTYPE=""; ROOT_DISK=""
    if have findmnt; then
        ROOT_SRC=$(findmnt -no SOURCE / 2>/dev/null)
        ROOT_FSTYPE=$(findmnt -no FSTYPE / 2>/dev/null)
    fi
    # ROOT_DISK is the whole-disk node behind the root partition, for checks
    # that need to read /sys/block/<disk> — the partition suffix differs by
    # bus: mmcblk0p2 and nvme0n1p1 strip "p<N>", sda1 strips a bare "<N>".
    # ROOT_MEDIA is the same fact in words, so the twelve modules can name the
    # medium in their own text instead of each growing a branch. Empty means
    # undetermined — modules stay generic rather than guessing a medium.
    ROOT_IS_SD=0; ROOT_IS_NVME=0; ROOT_IS_USB=0; ROOT_MEDIA=""
    case "$ROOT_SRC" in
        /dev/mmcblk*) ROOT_IS_SD=1;   ROOT_MEDIA="SD card"
                      ROOT_DISK=$(basename "${ROOT_SRC%p[0-9]*}") ;;
        /dev/nvme*)   ROOT_IS_NVME=1; ROOT_MEDIA="NVMe"
                      ROOT_DISK=$(basename "${ROOT_SRC%p[0-9]*}") ;;
        /dev/sd*)     ROOT_IS_USB=1;  ROOT_MEDIA="USB-attached disk"
                      ROOT_DISK=$(basename "${ROOT_SRC}" | sed 's/[0-9]*$//') ;;
    esac
    HAS_NVME=0
    compgen -G "/dev/nvme[0-9]n[0-9]" >/dev/null 2>&1 && HAS_NVME=1

    # --- peripherals ---------------------------------------------------------
    SDR_TYPE=""
    if have lsusb; then
        local usb; usb=$(lsusb 2>/dev/null)
        case "$usb" in
            *[Aa]irspy*)                  SDR_TYPE="airspy" ;;
            *RTL2838*|*"RTL2832"*)        SDR_TYPE="rtlsdr" ;;
            *HackRF*)                     SDR_TYPE="hackrf" ;;
            *SDRplay*)                    SDR_TYPE="sdrplay" ;;
        esac
    fi
    HAS_SDR=$([[ -n $SDR_TYPE ]] && echo 1 || echo 0)

    # --- software ------------------------------------------------------------
    HAS_DOCKER=0; have docker && HAS_DOCKER=1
    HAS_NM=0;     unit_exists NetworkManager.service && HAS_NM=1

    # Timing-sensitive workloads: MLAT wants tighter sync than timesyncd gives.
    DOES_MLAT=0
    local u
    for u in readsb.service piaware.service mlat-client.service dump1090-fa.service \
             airspy_adsb.service adsbexchange-mlat.service; do
        unit_exists "$u" && { DOES_MLAT=1; break; }
    done
    if [[ $DOES_MLAT -eq 0 && $HAS_DOCKER -eq 1 ]]; then
        docker ps --format '{{.Image}}' 2>/dev/null | grep -qiE 'adsb|piaware|readsb|airnav' && DOES_MLAT=1
    fi

    # Headless if no seat and no X/Wayland session.
    IS_HEADLESS=1
    if have loginctl && loginctl list-sessions --no-legend 2>/dev/null | grep -q seat; then
        IS_HEADLESS=0
    fi
    [[ -n ${DISPLAY:-} ]] && IS_HEADLESS=0

    # Wireless interfaces
    WIFI_IFACES=()
    if [[ -d /sys/class/net ]]; then
        local nic
        for nic in /sys/class/net/*; do
            [[ -d "$nic/wireless" || -e "$nic/phy80211" ]] && WIFI_IFACES+=("$(basename "$nic")")
        done
    fi

    # --- critical units to guard during apply --------------------------------
    # Anything currently running from this list must still be running afterward.
    CRITICAL_UNITS=()
    for u in ssh.service sshd.service tailscaled.service docker.service \
             readsb.service airspy_adsb.service piaware.service lighttpd.service \
             nginx.service systemd-networkd.service NetworkManager.service; do
        unit_active "$u" && CRITICAL_UNITS+=("$u")
    done
}

probe_summary() {
    printf '%s\n' \
        "Model      : $PI_MODEL" \
        "Distro     : ${DISTRO_PRETTY:-unknown}$([[ $IS_ARMBIAN -eq 1 ]] && echo ' (Armbian)')" \
        "Arch/pages : $ARCH, ${PAGE_SIZE}B pages, ${CPU_COUNT} cores, ${RAM_MB} MB RAM" \
        "Root       : ${ROOT_SRC:-?} (${ROOT_FSTYPE:-?})${ROOT_MEDIA:+ [$ROOT_MEDIA]}" \
        "Firmware   : ${CONFIG_TXT:-none found}" \
        "SDR        : ${SDR_TYPE:-none}$([[ $DOES_MLAT -eq 1 ]] && echo ' (MLAT workload detected)')" \
        "Docker     : $([[ $HAS_DOCKER -eq 1 ]] && echo yes || echo no)" \
        "Guarding   : ${CRITICAL_UNITS[*]:-none}"
}
