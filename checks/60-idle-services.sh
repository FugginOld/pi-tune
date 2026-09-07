#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# Disable daemons that ship enabled but do nothing on a typical headless Pi.
# Deliberately conservative: no bluetooth, no avahi (mDNS breaks .local names).
CHECK_ID="idle-services"
CHECK_TITLE="Disable unused stock daemons"
CHECK_RISK="low"

_candidates=(ModemManager.service triggerhappy.service cups.service cups-browsed.service)

_found() {
    local u
    for u in "${_candidates[@]}"; do
        unit_exists "$u" && { unit_active "$u" || unit_enabled "$u"; } && printf '%s\n' "$u"
    done
}

check_detect() {
    have systemctl || return 2
    [[ -n $(_found) ]] || return 0
    return 1
}

check_why() {
    local list; list=$(_found | tr '\n' ' ')
    echo "Running or enabled with nothing to do here: ${list% }"
}

check_apply() {
    local u any=0
    while read -r u; do
        [[ -n $u ]] || continue
        any=1
        [[ $DRY_RUN -eq 0 && -n ${BACKUP_DIR:-} ]] && printf '%s\n' "$u" >> "$BACKUP_DIR/idle-services.list"
        run systemctl disable --now "$u"
    done < <(_found)
    [[ $any -eq 1 ]] || info "nothing to disable"
    return 0
}

check_revert() {
    local f="${BACKUP_DIR:-}/idle-services.list" u
    [[ -f $f ]] || return 0
    while read -r u; do
        [[ -n $u ]] && run systemctl enable --now "$u"
    done < "$f"
    return 0
}
