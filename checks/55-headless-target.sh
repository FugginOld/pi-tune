#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# A headless box booting to graphical.target holds a display stack in RAM it
# never uses. Meaningful on a 1 GB Pi 3B.
CHECK_ID="headless-target"
CHECK_TITLE="Boot to multi-user (no desktop)"
CHECK_RISK="medium"

check_detect() {
    have systemctl || return 2
    [[ $IS_HEADLESS -eq 1 ]] || return 2
    local def; def=$(systemctl get-default 2>/dev/null)
    [[ $def == graphical.target ]] || return 0
    return 1
}

check_why() {
    echo "No local session in use but the default target is graphical.target (${RAM_MB} MB RAM total)."
}

check_impact() {
    cat <<'EOF'
Boots to multi-user instead of graphical, freeing the display stack's memory and a chunk of boot time - material on a 1 GB board. Attach a monitor later and you get a console, not a desktop, until you set the target back.
EOF
}

check_apply() {
    run systemctl set-default multi-user.target || return 1
    require_reboot
    require_manual "If you ever attach a monitor, restore the desktop with \`systemctl set-default graphical.target\`."
}

check_revert() { run systemctl set-default graphical.target; }
