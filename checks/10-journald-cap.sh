#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# Cap the persistent journal. Uncapped journals are a top cause of full
# SD cards on long-running Pis.
CHECK_ID="journald-cap"
CHECK_TITLE="Cap systemd journal size"
CHECK_RISK="low"

_jconf="/etc/systemd/journald.conf.d/99-pi-tune.conf"

check_detect() {
    have systemctl || return 2
    # Already capped anywhere in the config tree?
    if grep -rqsE '^[[:space:]]*SystemMaxUse=' /etc/systemd/journald.conf /etc/systemd/journald.conf.d/ 2>/dev/null; then
        return 0
    fi
    return 1
}

check_why() {
    local sz=""
    have journalctl && sz=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMG]' | tail -n1)
    echo "Journal is uncapped${sz:+ (currently ~$sz)}; a log storm can fill the card."
}

check_impact() {
    cat <<'EOF'
Caps the journal at 200 MB with a 500 MB free-space floor. Journald restarts, so a running journalctl -f drops. Nothing is deleted immediately; entries past the cap go at the next rotation.
EOF
}

check_apply() {
    write_drop_in "$_jconf" <<'EOF'
# pi-tune: bound journal growth so a chatty service can't fill the disk.
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
SystemKeepFree=500M
RuntimeMaxUse=64M
EOF
    run systemctl restart systemd-journald
}

# The restart has to happen after the drop-in is gone, or journald reloads
# the very cap we are removing and keeps it until its next restart.
check_revert_post() { run systemctl restart systemd-journald; }
