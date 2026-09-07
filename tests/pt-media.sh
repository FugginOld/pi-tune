set -uo pipefail
cd "$1" || exit 1
. lib/util.sh
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo yes ;; *) echo no ;; esac; }

# --- 1. ROOT_MEDIA derivation, exercising the real probe case statement ------
# probe_host does far more than this (systemd, lsusb, /proc reads), so calling it
# whole is not an option off-box. Instead of keeping a copy of the case statement
# here, extract and eval the real one: a copy needs a drift guard, and a guard
# that counts "ROOT_MEDIA=" lines still passes when a medium is renamed - which
# is the one drift that matters. No copy, nothing to drift.
media_block=$(sed -n '/ROOT_IS_SD=0; ROOT_IS_NVME=0/,/^    esac$/p' lib/probe.sh)
chk "probe block extracted" "$(grep -c 'ROOT_MEDIA=' <<<"$media_block")" 4
media_for() { ROOT_SRC="$1"; eval "$media_block"; }

media_for /dev/mmcblk0p2; chk "SD media"   "$ROOT_MEDIA" "SD card";           chk "SD disk"   "$ROOT_DISK" mmcblk0
media_for /dev/nvme0n1p1; chk "NVMe media" "$ROOT_MEDIA" "NVMe";              chk "NVMe disk" "$ROOT_DISK" nvme0n1
media_for /dev/sda2;      chk "USB media"  "$ROOT_MEDIA" "USB-attached disk"; chk "USB disk"  "$ROOT_DISK" sda
media_for /dev/mapper/vg-root
chk "unknown media empty" "${ROOT_MEDIA:-EMPTY}" EMPTY
chk "unknown sets no flag" "$((ROOT_IS_SD + ROOT_IS_NVME + ROOT_IS_USB))" 0

# --- 2. Modules interpolate the medium, and fall back when it is unknown -----
probe_as() { media_for "$1"; HAS_SDR=$2; SDR_TYPE=$3; }

probe_as /dev/mmcblk0p2 0 ""
unset -f check_why; . checks/10-journald-cap.sh
chk "journald names SD"      "$(has x "$(check_why)" 'fill the SD card')" yes

probe_as /dev/mapper/vg-root 0 ""
unset -f check_why; . checks/10-journald-cap.sh
chk "journald falls back"    "$(has x "$(check_why)" 'fill the root filesystem')" yes

probe_as /dev/sda2 0 ""
unset -f check_impact; . checks/25-zram-swap.sh
chk "zram names USB disk"    "$(has x "$(check_impact)" 'writes to the USB-attached disk')" yes
probe_as /dev/mapper/vg-root 0 ""
unset -f check_impact; . checks/25-zram-swap.sh
chk "zram falls back"        "$(has x "$(check_impact)" 'writes to the root device')" yes
chk "zram has no literal \$" "$(has x "$(check_impact)" '${ROOT_MEDIA')" no

# --- 3. usb-autosuspend gate and phrasing -----------------------------------
det() { unset -f check_detect check_why check_impact; . checks/30-usb-autosuspend.sh
        local rc=0; check_detect || rc=$?; echo "$rc"; }

probe_as /dev/mmcblk0p2 0 "";        chk "SD root, no SDR -> n/a"   "$(det)" 2
probe_as /dev/nvme0n1p1 0 "";        chk "NVMe root, no SDR -> n/a" "$(det)" 2
probe_as /dev/sda2      0 "";        chk "USB root, no SDR -> TUNE" "$(det)" 1
probe_as /dev/mmcblk0p2 1 "rtlsdr";  chk "SD root, SDR -> TUNE"     "$(det)" 1

probe_as /dev/sda2 0 ""; unset -f check_why check_impact; . checks/30-usb-autosuspend.sh
chk "USB-root why"        "$(has x "$(check_why)" 'stalls I/O to the boot device')" yes
chk "USB-root impact"     "$(has x "$(check_impact)" 'boot device is still exposed')" yes
# Effect states the cost of applying; the reason belongs to check_why, and the
# two sit adjacent on the review screen. Guard against restating it.
chk "impact names cmdline" "$(has x "$(check_impact)" 'kernel command line')" yes
chk "impact not a rerun of why" "$(has x "$(check_impact)" 'stalls I/O')" no

probe_as /dev/mmcblk0p2 1 "airspy"; unset -f check_why check_impact; . checks/30-usb-autosuspend.sh
chk "SDR why names type"  "$(has x "$(check_why)" 'airspy attached')" yes
chk "SDR impact is short" "$(has x "$(check_impact)" 'boot device is still exposed')" no

# Both true: the root-filesystem phrasing must win.
probe_as /dev/sda2 1 "rtlsdr"; unset -f check_why; . checks/30-usb-autosuspend.sh
chk "both -> root wins"   "$(has x "$(check_why)" 'stalls I/O to the boot device')" yes
chk "both -> not SDR text" "$(has x "$(check_why)" 'mid-capture')" no

exit $fail
