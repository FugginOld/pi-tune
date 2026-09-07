#!/usr/bin/env bash
# pi-tune — TUI-driven optimizer for Raspberry Pi hosts.
#
# Report-first by design: it never changes anything unless you pass --apply and
# tick the boxes. Every file it touches is snapshotted first and can be rolled
# back with --revert.
#
# Usage: pi-tune.sh [--report|--apply|--list|--revert TS] [options]

set -uo pipefail

PI_TUNE_VERSION="1.0.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHECK_DIR="${PI_TUNE_CHECK_DIR:-$SCRIPT_DIR/checks}"
LIB_DIR="$SCRIPT_DIR/lib"
BACKUP_ROOT="${PI_TUNE_BACKUP_ROOT:-/var/backups/pi-tune}"

MODE="report"
DRY_RUN=0
ASSUME_YES=0
NO_TUI=0
VERBOSE=0
ONLY=""
REVERT_TS=""
FLEET=""

# shellcheck source=lib/util.sh
. "$LIB_DIR/util.sh"
# shellcheck source=lib/probe.sh
. "$LIB_DIR/probe.sh"
# shellcheck source=lib/ui.sh
. "$LIB_DIR/ui.sh"

# --- check registry ---------------------------------------------------------

declare -a C_ID=() C_TITLE=() C_RISK=() C_FILE=() C_WHY=() C_IMPACT=() C_STATE=()

# load_check <file> — source a module in isolation. Functions and metadata are
# reset first so a module that omits one can't inherit the previous module's.
load_check() {
    local f=$1
    unset -f check_detect check_why check_impact check_apply check_revert check_revert_post
    CHECK_ID=""; CHECK_TITLE=""; CHECK_RISK="medium"
    check_detect() { return 2; }
    check_why()    { echo "(no rationale provided)"; }
    check_impact() { :; }
    check_apply()  { return 1; }
    check_revert()      { return 0; }
    check_revert_post() { return 0; }
    # shellcheck disable=SC1090
    . "$f" || { warn "failed to source $f"; return 1; }
    [[ -n $CHECK_ID ]] || { warn "$f: missing CHECK_ID"; return 1; }
    return 0
}

scan_checks() {
    local f rc
    shopt -s nullglob
    for f in "$CHECK_DIR"/*.sh; do
        load_check "$f" || continue
        if [[ -n $ONLY && ",$ONLY," != *",$CHECK_ID,"* ]]; then
            continue
        fi
        rc=0
        check_detect || rc=$?
        C_ID+=("$CHECK_ID")
        C_TITLE+=("$CHECK_TITLE")
        C_RISK+=("$CHECK_RISK")
        C_FILE+=("$f")
        C_WHY+=("$(check_why 2>/dev/null)")
        C_IMPACT+=("$(check_impact 2>/dev/null)")
        C_STATE+=("$rc")
        dbg "$CHECK_ID -> state $rc"
    done
    shopt -u nullglob
}

index_of() {
    local want=$1 i
    for i in "${!C_ID[@]}"; do
        [[ ${C_ID[$i]} == "$want" ]] && { echo "$i"; return 0; }
    done
    return 1
}

state_label() {
    case "$1" in
        0) printf '%sOK  %s' "$C_GRN" "$C_OFF" ;;
        1) printf '%sTUNE%s' "$C_YEL" "$C_OFF" ;;
        2) printf '%sn/a %s' "$C_DIM" "$C_OFF" ;;
        *) printf '????' ;;
    esac
}

# --- rationale rendering ----------------------------------------------------

# _field <label> <text> — one labelled paragraph, wrapped with a hanging indent
# so continuation lines line up under the first. 62 + 10 of indent stays inside
# whiptail's 78-column box.
_field() {
    local label=$1
    printf '%s\n' "$2" | fold -s -w 62 \
        | sed -e "1s/^/  $label /" -e "2,\$s/^/          /"
}

# review_text <index>... — the pre-checklist briefing: for every pending change,
# why this host was flagged and what applying it costs. Same content the report
# prints, gathered into one screen because the TUI clears the report away.
review_text() {
    local i
    printf '%d change(s) apply to %s.\nReview, then choose which to make.\n' \
        "$#" "$(hostname)"
    for i in "$@"; do
        printf '\n%s  [%s]\n' "${C_ID[$i]}" "${C_RISK[$i]}"
        _field 'Why:   ' "${C_WHY[$i]}"
        [[ -n ${C_IMPACT[$i]} ]] && _field 'Effect:' "${C_IMPACT[$i]}"
    done
}

# --- report -----------------------------------------------------------------

print_report() {
    local i pending=0
    printf '\n%spi-tune %s%s\n\n' "$C_BLD" "$PI_TUNE_VERSION" "$C_OFF"
    probe_summary | sed 's/^/  /'
    printf '\n  %sFindings%s\n\n' "$C_BLD" "$C_OFF"

    for i in "${!C_ID[@]}"; do
        [[ ${C_STATE[$i]} -eq 2 && $VERBOSE -eq 0 ]] && continue
        printf '  [%b] %-26s %s\n' "$(state_label "${C_STATE[$i]}")" "${C_ID[$i]}" "${C_TITLE[$i]}"
        if [[ ${C_STATE[$i]} -eq 1 ]]; then
            printf '%s' "$C_DIM"
            {
                _field 'Why:   ' "${C_WHY[$i]}"
                [[ -n ${C_IMPACT[$i]} ]] && _field 'Effect:' "${C_IMPACT[$i]}"
            } | sed 's/^/    /'
            printf '%s' "$C_OFF"
            pending=$((pending+1))
        fi
    done

    printf '\n  %d change(s) suggested.\n' "$pending"
    [[ $pending -gt 0 && $MODE == report ]] && \
        printf '  Re-run with %s--apply%s to choose which to make.\n' "$C_BLD" "$C_OFF"
    printf '\n'
    return 0
}

# --- apply ------------------------------------------------------------------

new_backup_dir() {
    BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"
        printf 'host=%s\nmodel=%s\nversion=%s\n' "$(hostname)" "$PI_MODEL" "$PI_TUNE_VERSION" \
            > "$BACKUP_DIR/manifest"
    fi
}

health_snapshot() {
    local u
    ACTIVE_BEFORE=()
    for u in "${CRITICAL_UNITS[@]:-}"; do
        [[ -n $u ]] && ACTIVE_BEFORE+=("$u")
    done
}

health_verify() {
    local u broken=()
    for u in "${ACTIVE_BEFORE[@]:-}"; do
        [[ -n $u ]] || continue
        unit_active "$u" || broken+=("$u")
    done
    if [[ ${#broken[@]} -gt 0 ]]; then
        err "these units were running before and are not now: ${broken[*]}"
        return 1
    fi
    info "health gate passed (${#ACTIVE_BEFORE[@]} unit(s) still active)"
    return 0
}

do_apply() {
    local -a pending=() items=()
    local i risk default

    for i in "${!C_ID[@]}"; do
        [[ ${C_STATE[$i]} -eq 1 ]] || continue
        pending+=("$i")
        risk="${C_RISK[$i]}"
        default=OFF
        [[ $risk == low ]] && default=ON
        items+=("${C_ID[$i]}" "[$risk] ${C_TITLE[$i]}" "$default")
    done

    if [[ ${#pending[@]} -eq 0 ]]; then
        info "nothing to do — everything detected is already in good shape"
        return 0
    fi

    local -a chosen=()
    if [[ $ASSUME_YES -eq 1 ]]; then
        for i in "${pending[@]}"; do
            [[ ${C_RISK[$i]} == low ]] && chosen+=("${C_ID[$i]}")
        done
        info "--yes: selecting ${#chosen[@]} low-risk change(s)"
        [[ ${#chosen[@]} -eq 0 ]] && { info "nothing selected"; return 0; }
    else
        # The TUI clears the screen, taking print_report's fingerprint with it.
        # Repeat the identifying facts here, where they are on screen at the
        # moment the boxes get ticked — being on the box you think you are on
        # matters more than any single item in the list.
        local out header
        printf -v header 'Host:   %s — %s\nSystem: %s, %s MB RAM, %s cores\nRoot:   %s (%s)%s\nLow-risk items are pre-selected; medium and high are not.' \
            "$(hostname)" "$PI_MODEL" "${DISTRO_PRETTY:-unknown}" "$RAM_MB" "$CPU_COUNT" \
            "${ROOT_SRC:-?}" "${ROOT_FSTYPE:-?}" "${ROOT_MEDIA:+ [$ROOT_MEDIA]}"
        # Checklist and confirmation are one loop. Answering Back on the
        # confirmation reopens the checklist with the ticks still set, so a
        # second thought costs one keypress instead of the whole selection.
        # Only in TUI mode: on the plain path print_report has already shown
        # all of this and is still on screen, so a second copy is noise.
        ui_available && ui_msgbox "pi-tune $PI_TUNE_VERSION — review" \
            "$(review_text "${pending[@]}")"

        local j sel
        while :; do
            if ! out=$(ui_checklist "pi-tune $PI_TUNE_VERSION" "$header" "${items[@]}"); then
                info "cancelled"
                return 0
            fi
            chosen=()
            [[ -n $out ]] && mapfile -t chosen <<< "$out"
            [[ ${#chosen[@]} -eq 0 ]] && { info "nothing selected"; return 0; }

            [[ $DRY_RUN -eq 1 ]] && break

            ui_yesno "Confirm" \
                "About to apply ${#chosen[@]} change(s) on $(hostname):\n\n$(printf '  - %s\n' "${chosen[@]}")\n\nOriginals are backed up and can be rolled back with --revert.\n\nChoose Back to return to the checklist." \
                Apply Back && break

            # Back: carry this selection into the next pass as the defaults.
            for ((j = 0; j < ${#items[@]}; j += 3)); do
                items[j + 2]=OFF
                for sel in "${chosen[@]}"; do
                    [[ ${items[$j]} == "$sel" ]] && items[j + 2]=ON
                done
            done
        done
    fi

    new_backup_dir
    health_snapshot

    local id idx rc applied=()
    for id in "${chosen[@]}"; do
        idx=$(index_of "$id") || continue
        info "applying $id — ${C_TITLE[$idx]}"
        load_check "${C_FILE[$idx]}" || continue
        # Recorded before the attempt: a module that fails halfway through has
        # still touched the system and must be reachable by --revert.
        [[ $DRY_RUN -eq 0 ]] && printf '%s\n' "$id" >> "$BACKUP_DIR/applied.list"
        rc=0
        check_apply || rc=$?
        if [[ $rc -eq 0 ]]; then
            applied+=("$id")
        else
            err "$id failed (exit $rc) — partial changes are covered by --revert"
        fi
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '\n'
        info "dry run complete — nothing was written"
        return 0
    fi

    printf '\n'
    info "applied ${#applied[@]} of ${#chosen[@]} change(s)"

    if ! health_verify; then
        if ui_yesno "Health check failed" "A service that was running before is now down.\n\nRoll back everything from this run?"; then
            do_revert "$(basename "$BACKUP_DIR")"
            return 1
        fi
    fi

    [[ -n $BACKUP_DIR ]] && info "rollback point: --revert $(basename "$BACKUP_DIR")"

    if [[ ${#NEEDS_MANUAL[@]} -gt 0 ]]; then
        printf '\n  %sManual follow-up needed:%s\n' "$C_BLD" "$C_OFF"
        printf '    - %s\n' "${NEEDS_MANUAL[@]}"
    fi
    if [[ $NEEDS_REBOOT -eq 1 ]]; then
        printf '\n  %sA reboot is required for some changes to take effect.%s\n\n' "$C_YEL" "$C_OFF"
    fi
    return 0
}

# --- revert -----------------------------------------------------------------

# revert_hooks <dir> <hook> — run one revert hook for every id in applied.list,
# re-sourcing its module first so the hook comes from the right file.
revert_hooks() {
    local dir=$1 hook=$2 id idx
    [[ -f "$dir/applied.list" ]] || return 0
    while read -r id; do
        [[ -n $id ]] || continue
        idx=$(index_of "$id") || continue
        load_check "${C_FILE[$idx]}" || continue
        dbg "$hook: $id"
        "$hook" || warn "$id $hook failed"
    done < "$dir/applied.list"
}

do_revert() {
    local ts=$1 dir
    if [[ $ts == last ]]; then
        dir=$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -n1)
    else
        dir="$BACKUP_ROOT/$ts"
    fi
    [[ -n $dir && -d $dir ]] || die "no such rollback point: $ts"

    info "reverting from $dir"

    # Modules that stashed a sidecar during apply (idle-services writes the
    # unit list it disabled) read it back through BACKUP_DIR. Without this the
    # path resolves to /<name> and the hook silently finds nothing.
    BACKUP_DIR="$dir"

    # 1. module-level undo that needs the applied config still on disk —
    #    disabling a unit whose unit file we are about to delete, for one.
    revert_hooks "$dir" check_revert

    # 2. restore every snapshotted file to its original path.
    if [[ -d "$dir/files" ]]; then
        local src dest
        while IFS= read -r -d '' src; do
            dest="${src#"$dir/files"}"
            info "restoring $dest"
            mkdir -p "$(dirname "$dest")"
            cp -a "$src" "$dest" || warn "could not restore $dest"
        done < <(find "$dir/files" -type f -print0)
    fi

    # 3. delete files we created that did not exist before.
    if [[ -f "$dir/created.list" ]]; then
        local p
        while read -r p; do
            [[ -n $p && -e $p ]] || continue
            info "removing $p"
            rm -f "$p"
        done < "$dir/created.list"
    fi

    # 4. remove directories we created, deepest first. rmdir refuses to touch
    #    a directory anything else has since put a file in, which is the
    #    behaviour we want — never rm -rf a path we only partly own.
    if [[ -f "$dir/created.dirs" ]]; then
        local d
        while read -r d; do
            [[ -n $d && -d $d ]] || continue
            rmdir "$d" 2>/dev/null && info "removing empty $d"
        done < "$dir/created.dirs"
    fi

    # 5. the on-disk state is now the original, so re-read it before the hooks
    #    that exist to make a running service notice.
    run systemctl daemon-reload
    if compgen -G "$dir/files/etc/sysctl.d/*" >/dev/null 2>&1; then
        run sysctl --quiet --system
    fi

    # 6. module-level undo that needs the ORIGINAL config back on disk —
    #    restarting journald, remounting / from the restored fstab, reloading
    #    NetworkManager. Running these in step 1 would have them pick up the
    #    very config we are removing.
    revert_hooks "$dir" check_revert_post

    info "revert complete — reboot if the original run required one"
}

list_rollbacks() {
    local d applied
    printf '\nRollback points in %s:\n\n' "$BACKUP_ROOT"
    while IFS= read -r d; do
        [[ -n $d ]] || continue
        applied=""
        [[ -f "$d/applied.list" ]] && applied=$(tr '\n' ' ' < "$d/applied.list")
        printf '  %-20s %s\n' "$(basename "$d")" "$applied"
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    printf '\n'
}

# --- fleet ------------------------------------------------------------------

do_fleet() {
    local hosts=$1 h
    IFS=',' read -ra h <<< "$hosts"
    local host
    for host in "${h[@]}"; do
        printf '\n%s=== %s ===%s\n' "$C_BLD" "$host" "$C_OFF"
        tar -C "$(dirname "$SCRIPT_DIR")" -cz "$(basename "$SCRIPT_DIR")" \
          | ssh -o BatchMode=yes "$host" \
              'set -e; d=$(mktemp -d); tar -C "$d" -xz; bash "$d"/*/pi-tune.sh --report --no-tui; rm -rf "$d"' \
          || warn "$host: failed"
    done
}

# --- entry ------------------------------------------------------------------

usage() {
    cat <<EOF
pi-tune $PI_TUNE_VERSION — Raspberry Pi optimization auditor

  --report            Audit only, change nothing (default)
  --apply             Audit, then offer a checklist of changes
  --dry-run           With --apply: show diffs and commands, write nothing
  --yes               Non-interactive; apply all low-risk items
  --revert TS|last    Roll back a previous run
  --rollbacks         List available rollback points
  --list              List all known checks and exit
  --only ID[,ID...]   Restrict to specific check IDs
  --no-tui            Force plain-text output
  --fleet h1,h2       SSH to each host and print its report
  -v, --verbose       Show n/a checks and debug output
  -h, --help          This

Backups live in $BACKUP_ROOT.
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --report)    MODE=report ;;
            --apply)     MODE=apply ;;
            --list)      MODE=list ;;
            --rollbacks) MODE=rollbacks ;;
            --revert)    MODE=revert; REVERT_TS="${2:-last}"; shift ;;
            --dry-run)   DRY_RUN=1 ;;
            --yes|-y)    ASSUME_YES=1 ;;
            --no-tui)    NO_TUI=1 ;;
            --only)      ONLY="${2:-}"; shift ;;
            --fleet)     MODE=fleet; FLEET="${2:-}"; shift ;;
            -v|--verbose) VERBOSE=1 ;;
            -h|--help)   usage; exit 0 ;;
            *)           die "unknown option: $1 (try --help)" ;;
        esac
        shift
    done

    [[ -d $CHECK_DIR ]] || die "check directory not found: $CHECK_DIR"

    if [[ $MODE == fleet ]]; then
        [[ -n $FLEET ]] || die "--fleet needs a host list"
        do_fleet "$FLEET"
        exit 0
    fi

    ui_init
    probe_host

    if [[ $MODE == rollbacks ]]; then
        list_rollbacks
        exit 0
    fi

    scan_checks

    case "$MODE" in
        list)
            local i
            for i in "${!C_ID[@]}"; do
                printf '%-26s %-8s %s\n' "${C_ID[$i]}" "[${C_RISK[$i]}]" "${C_TITLE[$i]}"
            done
            ;;
        report)
            print_report
            ;;
        revert)
            [[ $EUID -eq 0 ]] || die "revert needs root"
            do_revert "$REVERT_TS"
            ;;
        apply)
            [[ $EUID -eq 0 || $DRY_RUN -eq 1 ]] || die "--apply needs root (or use --dry-run)"
            print_report
            do_apply
            ;;
    esac
}

main "$@"
