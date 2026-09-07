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

# A candidate can be enabled-but-stopped, or running-but-not-enabled (started
# by hand). Record both bits so revert restores that exact state instead of
# flattening everything to "enabled and running".
check_apply() {
    local u any=0
    while read -r u; do
        [[ -n $u ]] || continue
        any=1
        if [[ $DRY_RUN -eq 0 && -n ${BACKUP_DIR:-} ]]; then
            printf '%s %s %s\n' "$u" \
                "$(unit_enabled "$u" && echo enabled || echo disabled)" \
                "$(unit_active  "$u" && echo active  || echo inactive)" \
                >> "$BACKUP_DIR/idle-services.list"
        fi
        run systemctl disable --now "$u"
    done < <(_found)
    [[ $any -eq 1 ]] || info "nothing to disable"
    return 0
}

check_revert() {
    local f="${BACKUP_DIR:-}/idle-services.list" u en act
    [[ -f $f ]] || return 0
    while read -r u en act; do
        [[ -n $u ]] || continue
        # Rollback points written before the state was recorded hold a bare
        # unit name; enable --now is what wrote them, so it is what undoes them.
        if [[ -z $en ]]; then
            run systemctl enable --now "$u"
            continue
        fi
        [[ $en == enabled ]] && run systemctl enable "$u"
        [[ $act == active ]] && run systemctl start "$u"
    done < "$f"
    return 0
}
