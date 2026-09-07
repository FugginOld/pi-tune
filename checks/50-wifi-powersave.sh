#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# WiFi power save causes the multi-second latency spikes people blame on
# "flaky WiFi" on headless Pis.
CHECK_ID="wifi-powersave"
CHECK_TITLE="Disable WiFi power save"
CHECK_RISK="low"

check_detect() {
    [[ ${#WIFI_IFACES[@]} -gt 0 ]] || return 2
    have iw || return 2
    local i
    for i in "${WIFI_IFACES[@]}"; do
        iw dev "$i" get power_save 2>/dev/null | grep -qi 'power save: on' && return 1
    done
    return 0
}

check_why() {
    echo "WiFi power save is on for ${WIFI_IFACES[*]} — expect periodic latency spikes and dropped sessions."
}

check_impact() {
    cat <<'EOF'
Stops the radio sleeping between beacons, removing the multi-second stalls usually blamed on flaky WiFi. Small constant increase in idle power. Applied live and persisted, so it survives reconnects and reboots.
EOF
}

check_apply() {
    if [[ $HAS_NM -eq 1 ]]; then
        write_drop_in /etc/NetworkManager/conf.d/99-pi-tune-powersave.conf <<'EOF'
# pi-tune: 2 = disable WiFi power saving.
[connection]
wifi.powersave = 2
EOF
        run systemctl reload NetworkManager.service
    else
        write_drop_in /etc/systemd/system/pi-tune-wifi-powersave.service <<'EOF'
[Unit]
Description=pi-tune: disable WiFi power save
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for i in $(ls /sys/class/net); do [ -d "/sys/class/net/$i/wireless" ] && iw dev "$i" set power_save off; done; true'

[Install]
WantedBy=multi-user.target
EOF
        run systemctl daemon-reload
        run systemctl enable --now pi-tune-wifi-powersave.service
    fi

    local i
    for i in "${WIFI_IFACES[@]}"; do
        run iw dev "$i" set power_save off || true
    done
    return 0
}

# Disabling our unit needs its unit file still present, so it stays here.
check_revert() {
    unit_exists pi-tune-wifi-powersave.service && run systemctl disable --now pi-tune-wifi-powersave.service
    return 0
}

# The NetworkManager reload has to come after our conf.d drop-in is deleted,
# otherwise NM re-reads powersave=2 and holds it.
check_revert_post() {
    [[ $HAS_NM -eq 1 ]] && run systemctl reload NetworkManager.service
    return 0
}
