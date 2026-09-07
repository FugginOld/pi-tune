#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# Pin the CPU to the performance governor on hosts doing real-time capture.
# Frequency ramping shows up as dropped samples and jittery timestamps.
CHECK_ID="cpu-governor"
CHECK_TITLE="Pin CPU governor to performance"
CHECK_RISK="medium"

_unit="/etc/systemd/system/pi-tune-governor.service"
_gov="/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"

check_detect() {
    [[ -r $_gov ]] || return 2
    # Only advise this where latency actually matters; elsewhere ondemand is
    # the better default for heat and power.
    [[ $HAS_SDR -eq 1 || $DOES_MLAT -eq 1 ]] || return 2
    [[ $(cat "$_gov") == performance ]] && return 0
    return 1
}

check_why() {
    echo "Governor is '$(cat "$_gov" 2>/dev/null)' on a capture host — clock ramping adds sample jitter."
}

check_impact() {
    cat <<'EOF'
Pins every core to its maximum clock. Removes frequency-ramp jitter from timing-sensitive capture at the cost of several degrees C and a few extra watts, continuously. A Pi 5 without active cooling may throttle - watch temperatures for a day before trusting it.
EOF
}

check_apply() {
    grep -qw performance /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors 2>/dev/null \
        || { err "performance governor not available on this kernel"; return 1; }

    write_drop_in "$_unit" <<'EOF'
[Unit]
Description=pi-tune: pin CPU scaling governor to performance
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done'

[Install]
WantedBy=multi-user.target
EOF
    run systemctl daemon-reload
    run systemctl enable --now pi-tune-governor.service
    require_manual "Watch temperatures for a day — performance governor runs hotter, especially on a Pi 5 without an active cooler."
}

check_revert() {
    run systemctl disable --now pi-tune-governor.service
    if [[ $DRY_RUN -eq 0 ]]; then
        local g
        for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo ondemand > "$g" 2>/dev/null || true
        done
    fi
    run systemctl daemon-reload
}
