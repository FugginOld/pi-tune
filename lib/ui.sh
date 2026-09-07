#!/usr/bin/env bash
# lib/ui.sh — thin wrapper over whiptail/dialog. Every entry point degrades to
# plain text so the tool still works over a dumb pipe or in CI.

UI_BIN=""
# Both backends silently clip text taller than the box - no bar, no marker, no
# error, the tail is just gone - and both need asking. They spell it
# differently: --scrolltext is newt's, and passing it to dialog is an unknown
# option rather than a no-op, so it cannot be hardcoded for both.
UI_SCROLL=()
# ui_pick_backend — pair the backend with its own spelling of the scroll flag.
# Separate from ui_init only because ui_init's first act is a tty test that a
# test harness cannot satisfy, and this pairing is the part worth pinning: the
# wrong flag here is not a degraded box, it is an unknown option and no dialog.
ui_pick_backend() {
    if have whiptail; then UI_BIN=whiptail; UI_SCROLL=(--scrolltext)
    elif have dialog;   then UI_BIN=dialog;  UI_SCROLL=(--scrollbar)
    else UI_BIN=""; UI_SCROLL=()
    fi
}

ui_init() {
    if [[ ${NO_TUI:-0} -eq 1 || ! -t 0 || ! -t 1 ]]; then
        UI_BIN=""; UI_SCROLL=()
        return 0
    fi
    ui_pick_backend
}

ui_available() { [[ -n $UI_BIN ]]; }

# ui_msgbox <title> <text> — one screen of read-only text. The scroll flag lets
# the backend page through content taller than the box, which the review screen
# needs once more than a couple of checks are pending.
ui_msgbox() {
    local title=$1 text=$2
    if ui_available; then
        # Verified on a Pi 3B+: the text scrolls, and neither --msgbox nor
        # --textbox draws a bar to say so. So overflow is reachable but silent -
        # the review screen read as truncated mid-sentence when it was only
        # scrolled to the top. Say it in the title, which stays visible and,
        # unlike a first line of body text, does not push the content down.
        # 22 lines of box less title, borders and button leaves ~16 for text,
        # wrapped to the 78-column box less its margins.
        [[ $(printf '%b\n' "$text" | fold -s -w 74 | wc -l) -gt 16 ]] &&
            title="$title — PgDn for more"
        "$UI_BIN" --title "$title" "${UI_SCROLL[@]}" --msgbox "$text" 22 78
    else
        printf '\n%b\n\n' "$text"
    fi
}

# Callers write line breaks as the "\n" escape, which is what whiptail expects.
# The fallback has to expand them itself, hence %b rather than %s.
# ui_yesno <title> <text> [yes-label] [no-label]
# Labels are whiptail-only; the plain-text fallback stays [y/N] because its
# reply is matched on the first letter, and "Apply"/"Back" would both fail it.
# Callers that relabel must therefore say in <text> what the no branch does.
ui_yesno() {
    local title=$1 text=$2 yes=${3:-} no=${4:-} reply
    local -a btn=()
    [[ -n $yes ]] && btn+=(--yes-button "$yes")
    [[ -n $no  ]] && btn+=(--no-button  "$no")
    if ui_available; then
        # The confirm dialog lists every pending change, so its text grows with
        # the run while the box stays 18 lines. Without the scroll flag a long
        # enough list loses its tail, and this is the screen the operator
        # approves a mutating run from.
        "$UI_BIN" --title "$title" "${btn[@]}" "${UI_SCROLL[@]}" --yesno "$text" 18 76
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
