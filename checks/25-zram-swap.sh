#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# zram-backed swap for small-memory boards. Compressed RAM swap beats swapping
# to the SD card by a wide margin and saves the card from write wear.
CHECK_ID="zram-swap"
CHECK_TITLE="Enable zram swap (low-memory boards)"
CHECK_RISK="low"

check_detect() {
    [[ $RAM_MB -gt 0 && $RAM_MB -le 2048 ]] || return 2
    # Armbian ships its own zram config; don't fight it.
    unit_active armbian-zram-config.service && return 0
    swapon --show=NAME --noheadings 2>/dev/null | grep -q zram && return 0
    return 1
}

check_why() {
    echo "${RAM_MB} MB RAM with no zram swap — memory pressure currently goes to disk or OOM."
}

check_apply() {
    pkg_install zram-tools || return 1

    write_drop_in /etc/default/zramswap <<'EOF'
# pi-tune: compressed swap sized at half of RAM.
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF

    sysctl_drop_in 99-pi-tune-zram.conf \
        'vm.swappiness=100' \
        'vm.vfs_cache_pressure=50' \
        'vm.page-cluster=0' || return 1

    run systemctl enable --now zramswap.service
}

check_revert() {
    run systemctl disable --now zramswap.service
    require_manual "zram-tools was installed; remove it with \`apt-get purge zram-tools\` if you want it gone."
}
