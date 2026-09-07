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

# ui_overflows <text> <lines> <cols> — is there more text than the box shows?
# Measured on wrapped lines, not newlines: at these widths one Effect paragraph
# wraps to four or five, so counting newlines calls an overflowing screen short.
ui_overflows() {
    [[ $(printf '%b\n' "$1" | fold -s -w "$3" | wc -l) -gt $2 ]]
}

# ui_msgbox <title> <text> — one screen of read-only text. The scroll flag lets
# the backend page through content taller than the box, which the review screen
# needs once more than a couple of checks are pending.
ui_msgbox() {
    local title=$1 text=$2
    local -a scroll=()
    if ui_available; then
        # Measured on a Pi 3B+, three msgboxes in one terminal: short text with
        # the flag draws a scrollbar, long text with it draws none, and long
        # text without it draws none either. So the bar appears only when there
        # is nothing to scroll to, which is worse than no bar - it implies more
        # below on a screen that is already complete. Pass the flag only on
        # overflow, and say so in the title, which stays visible and, unlike a
        # leading line of body text, does not push the content down to make room
        # for the notice about content being pushed down.
        # 22 lines of box less title, borders and button leaves ~16 for text.
        if ui_overflows "$text" 16 74; then
            title="$title — PgDn for more"
            scroll=("${UI_SCROLL[@]}")
        fi
        "$UI_BIN" --title "$title" "${scroll[@]}" --msgbox "$text" 22 78
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
        # Same rule as ui_msgbox, with this box's own dimensions: 18 lines less
        # chrome leaves ~14. The confirm text lists every pending change, so it
        # grows with the run, and this is the screen the operator approves a
        # mutating run from - the worst one to leave a silent tail on.
        local -a scroll=()
        if ui_overflows "$text" 14 72; then
            title="$title — PgDn for more"
            scroll=("${UI_SCROLL[@]}")
        fi
        "$UI_BIN" --title "$title" "${btn[@]}" "${scroll[@]}" --yesno "$text" 18 76
        return $?
    fi
    printf '\n%b\n%s [y/N] ' "$text" "$title" >&2
    read -r reply || return 1
    [[ $reply =~ ^[Yy] ]]
}

# ui_menu <title> <text> <tag> <label> ... — one choice from a list. Prints the
# chosen tag on stdout. rc 1 is Cancel and rc 255 is Esc, and callers must tell
# those apart on any screen that authorises a change: Cancel means go back,
# Esc means leave without doing it.
#
# Measured on whiptail 2026-09-07 rather than assumed, after --extra-button
# turned out not to exist at all: the tag arrives on stderr through the same
# 3>&1 1>&2 2>&3 the checklist uses, every selection returns 0 with the tag
# carrying the choice, and \n in the body expands with indent preserved - which
# is what lets a caller put a list of changes above the rows.
ui_menu() {
    local title=$1 text=$2; shift 2
    local -a items=("$@")
    local count=$(( ${#items[@]} / 2 ))

    if ui_available; then
        # The list eats rows the body would otherwise get, so the overflow
        # budget shrinks as the menu grows rather than being a fixed number.
        local lh=$count
        [[ $lh -gt 10 ]] && lh=10
        local budget=$(( 22 - lh - 6 ))
        [[ $budget -lt 3 ]] && budget=3

        local -a scroll=()
        if ui_overflows "$text" "$budget" 74; then
            title="$title — PgDn for more"
            scroll=("${UI_SCROLL[@]}")
        fi

        local out rc
        out=$("$UI_BIN" --title "$title" "${scroll[@]}" \
              --menu "$text" 22 78 "$lh" "${items[@]}" 3>&1 1>&2 2>&3)
        rc=$?
        [[ $rc -eq 0 ]] && printf '%s\n' "$out"
        return $rc
    fi

    # Plain-text fallback, mirroring ui_checklist's numbered form. %b, because
    # callers write line breaks as the "\n" escape whiptail expects.
    local -a tags=() labels=()
    local i=0
    while [[ $i -lt ${#items[@]} ]]; do
        tags+=("${items[$i]}")
        labels+=("${items[$((i+1))]}")
        i=$((i+2))
    done

    printf '\n%b\n\n' "$text" >&2
    for i in "${!tags[@]}"; do
        printf '  %2d) %s\n' "$((i+1))" "${labels[$i]}" >&2
    done
    printf '\nSelect a number, or Enter to go back: ' >&2

    local reply
    # EOF is not a choice to go back - it is no terminal at all, which on a
    # screen that authorises a change has to mean abort, the same as Esc.
    read -r reply || return 255
    [[ -n $reply && $reply =~ ^[0-9]+$ ]] || return 1
    [[ $reply -ge 1 && $reply -le ${#tags[@]} ]] || return 1
    printf '%s\n' "${tags[$((reply-1))]}"
    return 0
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
