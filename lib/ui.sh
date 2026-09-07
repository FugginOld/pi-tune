#!/usr/bin/env bash
# lib/ui.sh — thin wrapper over whiptail/dialog. Every entry point degrades to
# plain text so the tool still works over a dumb pipe or in CI.

UI_BIN=""
ui_init() {
    if [[ ${NO_TUI:-0} -eq 1 || ! -t 0 || ! -t 1 ]]; then
        UI_BIN=""
        return 0
    fi
    if have whiptail; then UI_BIN=whiptail
    elif have dialog;   then UI_BIN=dialog
    else UI_BIN=""
    fi
}

ui_available() { [[ -n $UI_BIN ]]; }

# Callers write line breaks as the "\n" escape, which is what whiptail expects.
# The fallback has to expand them itself, hence %b rather than %s.
ui_yesno() {
    local title=$1 text=$2 reply
    if ui_available; then
        "$UI_BIN" --title "$title" --yesno "$text" 18 76
        return $?
    fi
    printf '\n%b\n%s [y/N] ' "$text" "$title" >&2
    read -r reply || return 1
    [[ $reply =~ ^[Yy] ]]
}

# ui_checklist <title> <text> <tag> <desc> <on|off> ...
# Prints selected tags, one per line, on stdout.
ui_checklist() {
    local title=$1 text=$2; shift 2
    local -a items=("$@")

    if ui_available; then
        local out rc
        out=$("$UI_BIN" --title "$title" --separate-output \
              --checklist "$text" 22 78 12 "${items[@]}" 3>&1 1>&2 2>&3)
        rc=$?
        [[ $rc -ne 0 ]] && return 1
        printf '%s\n' "$out" | tr -d '"' | grep -v '^$'
        return 0
    fi

    # Plain-text fallback: numbered list, comma-separated selection.
    local -a tags=() descs=() defaults=()
    local i=0
    while [[ $i -lt ${#items[@]} ]]; do
        tags+=("${items[$i]}")
        descs+=("${items[$((i+1))]}")
        defaults+=("${items[$((i+2))]}")
        i=$((i+3))
    done

    printf '\n%b\n\n' "$text" >&2
    for i in "${!tags[@]}"; do
        printf '  %2d) [%s] %s\n' "$((i+1))" \
            "$([[ ${defaults[$i]} == ON ]] && echo x || echo ' ')" "${descs[$i]}" >&2
    done
    printf '\nSelect numbers (comma separated), "all", "none", or Enter for defaults: ' >&2

    local reply; read -r reply || return 1
    case "$reply" in
        none) return 0 ;;
        all)  printf '%s\n' "${tags[@]}"; return 0 ;;
        "")
            for i in "${!tags[@]}"; do
                [[ ${defaults[$i]} == ON ]] && printf '%s\n' "${tags[$i]}"
            done
            return 0 ;;
    esac

    local n
    IFS=',' read -ra n <<< "$reply"
    for i in "${n[@]}"; do
        i="${i// /}"
        [[ $i =~ ^[0-9]+$ ]] || continue
        [[ $i -ge 1 && $i -le ${#tags[@]} ]] && printf '%s\n' "${tags[$((i-1))]}"
    done
    return 0
}
