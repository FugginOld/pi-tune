#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# systemd-timesyncd is an SNTP client and drifts more than MLAT likes.
# chrony disciplines the clock properly.
CHECK_ID="chrony-timesync"
CHECK_TITLE="Use chrony instead of systemd-timesyncd"
CHECK_RISK="low"

# Debian names the unit chrony.service; several other packagings (and older
# Armbian images) ship it as chronyd.service. Resolve once so detect, apply and
# revert can never act on different names. Falls back to chrony.service, which
# is what the Debian package we install provides.
_chrony_unit() {
    local u
    for u in chrony.service chronyd.service; do
        unit_exists "$u" && { printf '%s' "$u"; return 0; }
    done
    printf 'chrony.service'
}

check_detect() {
    [[ $DOES_MLAT -eq 1 ]] || return 2
    unit_active "$(_chrony_unit)" && return 0
    return 1
}

check_why() {
    echo "MLAT workload detected but time is kept by $(unit_active systemd-timesyncd.service && echo systemd-timesyncd || echo 'no disciplined NTP client')."
}

check_apply() {
    pkg_install chrony || return 1
    if unit_exists systemd-timesyncd.service; then
        run systemctl disable --now systemd-timesyncd.service
    fi
    # Resolved after the install: on a box with no chrony at all, the unit only
    # exists once the package is on disk.
    run systemctl enable --now "$(_chrony_unit)"
    require_manual "Check sync quality in a few minutes with \`chronyc tracking\` (RMS offset should settle under a millisecond)."
}

check_revert() {
    run systemctl disable --now "$(_chrony_unit)"
    unit_exists systemd-timesyncd.service && run systemctl enable --now systemd-timesyncd.service
    require_manual "chrony was installed but not removed; purge it manually if you want it gone."
    return 0
}
