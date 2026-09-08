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

MODE="auto"
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

# The registry is one module: load it, ask it for ids, ask it about an id. The
# arrays below are its implementation and nothing outside these functions reads
# them. They used to be seven parallel arrays indexed by position from fourteen
# places, where a one-element skew meant index_of returned an index apply_ids
# then used against C_FILE - sourcing the wrong module under the right label.
# Keyed by id, that failure cannot be expressed.
declare -a REG_IDS=()
declare -A REG_TITLE=() REG_RISK=() REG_FILE=() REG_WHY=() REG_IMPACT=() REG_STATE=()

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

# registry_load — scan CHECK_DIR, run every detect, replace whatever was here.
# Replaces rather than appends, so calling it twice is a refresh and not a
# doubling. That is what lets a screen re-read the world after changing it; the
# append-only version is why screen_revert could only rebuild the applied index
# and had to leave the detect results stale.
registry_load() {
    local f rc
    REG_IDS=()
    REG_TITLE=(); REG_RISK=(); REG_FILE=(); REG_WHY=(); REG_IMPACT=(); REG_STATE=()
    shopt -s nullglob
    for f in "$CHECK_DIR"/*.sh; do
        load_check "$f" || continue
        if [[ -n $ONLY && ",$ONLY," != *",$CHECK_ID,"* ]]; then
            continue
        fi
        rc=0
        check_detect || rc=$?
        REG_IDS+=("$CHECK_ID")
        REG_TITLE[$CHECK_ID]=$CHECK_TITLE
        REG_RISK[$CHECK_ID]=$CHECK_RISK
        REG_FILE[$CHECK_ID]=$f
        REG_WHY[$CHECK_ID]=$(check_why 2>/dev/null)
        REG_IMPACT[$CHECK_ID]=$(check_impact 2>/dev/null)
        REG_STATE[$CHECK_ID]=$rc
        dbg "$CHECK_ID -> state $rc"
    done
    shopt -u nullglob
}

# An empty registry prints nothing. printf runs its format once even with no
# arguments, so the obvious one-liner emitted a blank line, and a blank id read
# back as an empty subscript - `--list --only nosuchid` printed two `REG_STATE:
# bad array subscript` errors and a row of padding.
registry_ids() {
    [[ ${#REG_IDS[@]} -gt 0 ]] || return 0
    printf '%s\n' "${REG_IDS[@]}"
}

registry_has() { [[ -n ${REG_STATE[${1:-}]:-} ]]; }

# registry_get <id> <field> — title | risk | file | why | impact. An unknown id
# is rc 1, not an empty string: the positional version silently handed back a
# neighbour's field, and that is the bug this module exists to make unsayable.
registry_get() {
    registry_has "$1" || return 1
    case "$2" in
        title)  printf '%s\n' "${REG_TITLE[$1]}" ;;
        risk)   printf '%s\n' "${REG_RISK[$1]}" ;;
        file)   printf '%s\n' "${REG_FILE[$1]}" ;;
        why)    printf '%s\n' "${REG_WHY[$1]}" ;;
        impact) printf '%s\n' "${REG_IMPACT[$1]}" ;;
        *)      return 1 ;;
    esac
}

registry_state() { registry_has "$1" || return 1; printf '%s\n' "${REG_STATE[$1]}"; }

# registry_tunables — ids whose detect said "applies here and is not set".
registry_tunables() {
    local id
    for id in ${REG_IDS[@]+"${REG_IDS[@]}"}; do
        [[ ${REG_STATE[$id]} -eq 1 ]] && printf '%s\n' "$id"
    done
    return 0
}

# registry_checklist_rows — tag/label/default triples for every tunable, one per
# line. do_apply and screen_select built this identically, eight lines each.
registry_checklist_rows() {
    local id risk title default
    while read -r id; do
        [[ -n $id ]] || continue
        # Three lines per item, so a newline inside a title or risk would shift
        # every triple after it and the caller's stride-3 read would take one
        # item's tag from another's label. The module author picks these strings;
        # the registry is where that stops being their problem.
        risk=${REG_RISK[$id]//$'\n'/ }
        title=${REG_TITLE[$id]//$'\n'/ }
        default=OFF
        [[ $risk == low ]] && default=ON
        printf '%s\n[%s] %s\n%s\n' "$id" "$risk" "$title" "$default"
    done < <(registry_tunables)
}

# APPLIED[id] = timestamp of the most recent run that applied that check and has
# not been reverted. Read-only, and every failure path here degrades to "empty"
# rather than guessing — report mode runs unprivileged and may not be able to
# read BACKUP_ROOT at all.
declare -A APPLIED=()

# applied_index — which checks pi-tune itself applied, across every rollback
# point. "Already satisfied" and "we did it" are different facts: root-noatime
# reads satisfied on a stock box pi-tune never touched, while journald-cap reads
# satisfied because we capped it. Only the second is revertable, so only the
# second is DONE. Sorted ascending, so the newest run wins.
applied_index() {
    local d id
    APPLIED=()
    [[ -d $BACKUP_ROOT ]] || return 0
    while IFS= read -r d; do
        [[ -n $d && -r "$d/applied.list" ]] || continue
        # A whole-run revert of a pre-schema-2 point marks the run, not the
        # module, because there is no module level in it to mark.
        [[ -e "$d/reverted" ]] && continue
        while read -r id; do
            # A tune that was reverted is not applied any more. Phase 2 writes
            # this marker per module; until then nothing carries it and every
            # id in applied.list counts.
            [[ -n $id && ! -e "$d/modules/$id/reverted" ]] && APPLIED[$id]=$(basename "$d")
        done < "$d/applied.list"
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    return 0
}

# state_label <rc> [id] — the rc is check_detect's three-state contract and does
# not change. DONE is a presentation split of state 0 against APPLIED, not a
# fourth return code: making it one would ripple into all twelve modules.
# state_word <rc> [id] — the bare word, no colour. The TUI needs this: an
# escape sequence inside a whiptail body renders as garbage, not as colour.
state_word() {
    case "$1" in
        0) if [[ -n ${2:-} && -n ${APPLIED[${2}]:-} ]]; then echo DONE; else echo OK; fi ;;
        1) echo TUNE ;;
        2) echo "N/A" ;;
        *) echo "????" ;;
    esac
}

state_label() {
    local w c
    w=$(state_word "$1" "${2:-}")
    case "$w" in
        TUNE) c=$C_YEL ;;
        "N/A") c=$C_DIM ;;
        *)    c=$C_GRN ;;
    esac
    printf '%s%-4s%s' "$c" "$w" "$C_OFF"
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
    local id impact
    printf '%d change(s) apply to %s.\nReview, then choose which to make.\n' \
        "$#" "$(hostname)"
    for id in "$@"; do
        printf '\n%s  [%s]\n' "$id" "$(registry_get "$id" risk)"
        _field 'Why:   ' "$(registry_get "$id" why)"
        impact=$(registry_get "$id" impact)
        [[ -n $impact ]] && _field 'Effect:' "$impact"
    done
}

# --- report -----------------------------------------------------------------

print_report() {
    local pending=0 id st impact
    printf '\n%spi-tune %s%s\n\n' "$C_BLD" "$PI_TUNE_VERSION" "$C_OFF"
    probe_summary | sed 's/^/  /'
    printf '\n  %sFindings%s\n\n' "$C_BLD" "$C_OFF"

    while read -r id; do
        [[ -n $id ]] || continue
        st=$(registry_state "$id")
        [[ $st -eq 2 && $VERBOSE -eq 0 ]] && continue
        printf '  [%b] %-26s %s\n' "$(state_label "$st" "$id")" "$id" "$(registry_get "$id" title)"
        if [[ $st -eq 1 ]]; then
            printf '%s' "$C_DIM"
            {
                _field 'Why:   ' "$(registry_get "$id" why)"
                impact=$(registry_get "$id" impact)
                [[ -n $impact ]] && _field 'Effect:' "$impact"
            } | sed 's/^/    /'
            printf '%s' "$C_OFF"
            pending=$((pending+1))
        fi
    done < <(registry_ids)

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
        # schema=2 means per-module subtrees under modules/. Its absence means
        # a pre-2 run with one files/ tree at the root, which reverts whole.
        printf 'host=%s\nmodel=%s\nversion=%s\nschema=2\n' \
            "$(hostname)" "$PI_MODEL" "$PI_TUNE_VERSION" \
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
    mapfile -t pending < <(registry_tunables)
    mapfile -t items   < <(registry_checklist_rows)

    if [[ ${#pending[@]} -eq 0 ]]; then
        info "nothing to do — everything detected is already in good shape"
        return 0
    fi

    local -a chosen=()
    if [[ $ASSUME_YES -eq 1 ]]; then
        local id
        for id in "${pending[@]}"; do
            [[ $(registry_get "$id" risk) == low ]] && chosen+=("$id")
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

    apply_ids ${chosen[@]+"${chosen[@]}"}
}

# apply_ids <id>... — the mutating half of an apply: backup point, health
# snapshot, run each module, health gate, then the manual and reboot notes.
# Split out so --apply's flow and the interactive screens share exactly one path
# that writes. Two write paths would be two places to get the backup wrong.
apply_ids() {
    local -a chosen=("$@")
    [[ ${#chosen[@]} -gt 0 ]] || { info "nothing selected"; return 0; }
    new_backup_dir
    health_snapshot

    local id rc applied=() run_dir=$BACKUP_DIR
    for id in "${chosen[@]}"; do
        registry_has "$id" || continue
        info "applying $id — $(registry_get "$id" title)"
        load_check "$(registry_get "$id" file)" || continue
        # Recorded before the attempt: a module that fails halfway through has
        # still touched the system and must be reachable by --revert.
        [[ $DRY_RUN -eq 0 ]] && printf '%s\n' "$id" >> "$run_dir/applied.list"
        # backup_file, record_absent, record_new_dirs and every module sidecar
        # resolve through BACKUP_DIR. Pointing it at this module's own subtree
        # files all of them there with no change to any of those helpers - and
        # is what makes reverting one tune without the others possible at all.
        BACKUP_DIR="$run_dir/modules/$id"
        [[ $DRY_RUN -eq 0 ]] && mkdir -p "$BACKUP_DIR"
        rc=0
        check_apply || rc=$?
        [[ $DRY_RUN -eq 0 ]] && record_post_hashes
        BACKUP_DIR=$run_dir
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

# record_post_hashes — what this module left on disk, hashed, so a later
# per-tune revert can tell "nothing has touched this since" from "something
# has". The paths are the ones the module actually wrote: whatever it
# overwrote (mirrored under files/) plus whatever it created (created.list).
record_post_hashes() {
    local src dest
    [[ -n ${BACKUP_DIR:-} && -d $BACKUP_DIR ]] || return 0
    : > "$BACKUP_DIR/post.sha256"
    if [[ -d "$BACKUP_DIR/files" ]]; then
        while IFS= read -r -d '' src; do
            dest="${src#"$BACKUP_DIR/files"}"
            [[ -f $dest ]] && sha256sum "$dest" >> "$BACKUP_DIR/post.sha256"
        done < <(find "$BACKUP_DIR/files" -type f -print0 2>/dev/null)
    fi
    if [[ -f "$BACKUP_DIR/created.list" ]]; then
        while read -r dest; do
            [[ -n $dest && -f $dest ]] && sha256sum "$dest" >> "$BACKUP_DIR/post.sha256"
        done < "$BACKUP_DIR/created.list"
    fi
    return 0
}

# _post_hash <moddir> <dest> — what we left at that path, or rc 1 if unrecorded.
# sha256sum prints a 64-char hash, two spaces, then the path.
_post_hash() {
    local line
    [[ -f "$1/post.sha256" ]] || return 1
    while IFS= read -r line; do
        [[ ${line:66} == "$2" ]] && { printf '%s' "${line:0:64}"; return 0; }
    done < "$1/post.sha256"
    return 1
}

# _drifted <moddir> <dest> — has anything changed this file since we applied it?
# Per-tune revert is what makes this reachable: restoring blindly would undo a
# later change pi-tune did not make. An unrecorded path means we cannot tell,
# and the old restore-anyway behaviour stands rather than silently skipping.
_drifted() {
    local want now
    want=$(_post_hash "$1" "$2") || return 1
    [[ -f $2 ]] || return 1
    now=$(sha256sum "$2" | cut -c1-64)
    [[ $now != "$want" ]]
}

# _revert_hook <id> <hook> — one revert hook, from the right module file.
_revert_hook() {
    registry_has "$1" || return 0
    load_check "$(registry_get "$1" file)" || return 0
    dbg "$2: $1"
    "$2" || warn "$1 $2 failed"
}

# A rollback point is undone as a list of backup subtrees. Schema 2 has one per
# applied module; schema 1 has no per-module level at all, so its single subtree
# is the run directory itself. That is the only difference between them, and it
# is expressed here rather than by keeping two copies of the walk - the two used
# to run the same five phases with the restore, delete and rmdir loops written
# out near-verbatim in both.
declare -a REVERT_SUBS=()

# _revert_plan <dir> [id...] — fill REVERT_SUBS with what to undo, in undo
# order. Fills an array rather than printing, because info and warn go to the
# same stdout a printed list would use.
#
# Ids are silently ignored under schema 1, which has no per-module level to
# narrow to. do_revert refuses that combination before calling here; a new
# caller that skips do_revert would quietly revert the whole run instead.
_revert_plan() {
    local dir=$1; shift
    local -a want=("$@") ids=()
    local id w hit m
    REVERT_SUBS=()

    if ! grep -qs '^schema=2$' "$dir/manifest"; then
        [[ -e "$dir/reverted" ]] && { info "already reverted"; return 0; }
        REVERT_SUBS=("$dir")
        return 0
    fi

    # applied.list is apply order; undo in reverse.
    while read -r id; do
        [[ -n $id ]] && ids=("$id" ${ids[@]+"${ids[@]}"})
    done < "$dir/applied.list"

    for id in ${ids[@]+"${ids[@]}"}; do
        m="$dir/modules/$id"
        [[ -d $m ]] || { warn "$id has no per-module backup here"; continue; }
        [[ -e "$m/reverted" ]] && { info "$id already reverted"; continue; }
        if [[ ${#want[@]} -gt 0 ]]; then
            hit=0
            for w in "${want[@]}"; do [[ $w == "$id" ]] && hit=1; done
            [[ $hit -eq 1 ]] || continue
        fi
        REVERT_SUBS+=("$m")
    done
}

# _subtree_ids <dir> <subtree> — the module ids whose hooks belong to this
# subtree. Under schema 2 a subtree is one module and its name says which; under
# schema 1 the one subtree owns the whole run, so applied.list says.
_subtree_ids() {
    if [[ $2 == "$1" ]]; then
        [[ -f "$1/applied.list" ]] && cat "$1/applied.list"
        return 0
    fi
    basename "$2"
}

# _revert_walk <dir> — the five phases, over REVERT_SUBS. Phases run across all
# subtrees before the next begins: doing one subtree end to end would run its
# post hook - a reload - over another's not-yet-restored config.
_revert_walk() {
    local dir=$1
    local sub id src dest pth d kv
    [[ ${#REVERT_SUBS[@]} -gt 0 ]] || { warn "nothing to revert"; return 0; }

    # 1. undo that needs the applied config still on disk — disabling a unit
    #    whose unit file we are about to delete, for one. BACKUP_DIR is pointed
    #    at the subtree so a module reads back the sidecar it wrote during
    #    apply; without it the path resolves to /<name> and the hook silently
    #    finds nothing.
    for sub in "${REVERT_SUBS[@]}"; do
        BACKUP_DIR="$sub"
        while read -r id; do
            [[ -n $id ]] && _revert_hook "$id" check_revert
        done < <(_subtree_ids "$dir" "$sub")
    done

    # 2. restore, delete, rmdir — each subtree out of its own tree. A file that
    #    changed since we applied it is left alone: restoring blind would undo
    #    an edit pi-tune did not make. A subtree that recorded no hashes cannot
    #    be judged, and there the old restore-anyway behaviour stands.
    for sub in "${REVERT_SUBS[@]}"; do
        if [[ -d "$sub/files" ]]; then
            while IFS= read -r -d '' src; do
                dest="${src#"$sub/files"}"
                if _drifted "$sub" "$dest"; then
                    warn "$dest changed since $(basename "$sub") was applied — left as it is"
                    continue
                fi
                info "restoring $dest"
                mkdir -p "$(dirname "$dest")"
                cp -a "$src" "$dest" || warn "could not restore $dest"
            done < <(find "$sub/files" -type f -print0)
        fi
        if [[ -f "$sub/created.list" ]]; then
            while read -r pth; do
                [[ -n $pth && -e $pth ]] || continue
                if _drifted "$sub" "$pth"; then
                    warn "$pth changed since $(basename "$sub") was applied — left as it is"
                    continue
                fi
                info "removing $pth"
                rm -f "$pth"
            done < "$sub/created.list"
        fi
        # rmdir refuses a directory anything else has since put a file in,
        # which is what we want — never rm -rf a path we only partly own.
        if [[ -f "$sub/created.dirs" ]]; then
            while read -r d; do
                [[ -n $d && -d $d ]] || continue
                rmdir "$d" 2>/dev/null && info "removing empty $d"
            done < "$sub/created.dirs"
        fi
    done

    # 3. the on-disk state is the original again; re-read it once for the batch.
    run systemctl daemon-reload
    for sub in "${REVERT_SUBS[@]}"; do
        if compgen -G "$sub/files/etc/sysctl.d/*" >/dev/null 2>&1; then
            run sysctl --quiet --system
            break
        fi
    done

    # A drop-in this run created is simply gone now, and --system re-reads only
    # what files still mention. The values recorded before the write are the
    # only route back to what the kernel had.
    for sub in "${REVERT_SUBS[@]}"; do
        [[ -f "$sub/sysctl.pre" ]] || continue
        while IFS= read -r kv; do
            [[ -n $kv ]] || continue
            info "restoring ${kv%%=*}"
            run sysctl --quiet -w "$kv"
        done < "$sub/sysctl.pre"
    done

    # 4. undo that needs the ORIGINAL config back on disk — restarting journald,
    #    remounting / from the restored fstab, reloading NetworkManager. In
    #    phase 1 these would pick up the very config being removed.
    for sub in "${REVERT_SUBS[@]}"; do
        BACKUP_DIR="$sub"
        while read -r id; do
            [[ -n $id ]] && _revert_hook "$id" check_revert_post
        done < <(_subtree_ids "$dir" "$sub")
    done

    # 5. mark, so DONE stops claiming them and they are not offered again. One
    #    rule for both schemas: the marker goes in the subtree, and under schema
    #    1 the subtree is the run. do_revert used to write the schema-1 marker
    #    itself while the schema-2 walk wrote its own.
    for sub in "${REVERT_SUBS[@]}"; do
        date +%Y%m%d-%H%M%S > "$sub/reverted"
    done
}

# do_revert <ts|last> [id...] — ids revert single tunes, and only on schema 2.
do_revert() {
    local ts=$1; shift
    local -a want=("$@")
    local dir
    if [[ $ts == last ]]; then
        dir=$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort | tail -n1)
    else
        dir="$BACKUP_ROOT/$ts"
    fi
    [[ -n $dir && -d $dir ]] || die "no such rollback point: $ts"

    info "reverting from $dir"

    # --only needs a per-module level to narrow to. A schema-1 point has none,
    # so it is refused rather than quietly undoing the whole run.
    grep -qs '^schema=2$' "$dir/manifest" || [[ ${#want[@]} -eq 0 ]] || \
        die "$(basename "$dir") predates per-module backups and can only be reverted whole"

    _revert_plan "$dir" ${want[@]+"${want[@]}"}
    _revert_walk "$dir"

    info "revert complete — reboot if the original run required one"
}

list_rollbacks() {
    local d id applied
    printf '\nRollback points in %s:\n\n' "$BACKUP_ROOT"
    while IFS= read -r d; do
        [[ -n $d ]] || continue
        applied=""
        if [[ -f "$d/applied.list" ]]; then
            # Now that one tune can be reverted out of a run, listing an
            # already-undone one as still revertable would be a lie.
            while read -r id; do
                [[ -n $id ]] || continue
                if [[ -e "$d/modules/$id/reverted" ]]; then
                    applied+="$id(reverted) "
                else
                    applied+="$id "
                fi
            done < "$d/applied.list"
        fi
        grep -qs '^schema=2$' "$d/manifest" || applied+="[whole-run only]"
        printf '  %-20s %s\n' "$(basename "$d")" "$applied"
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    printf '\n'
}

# --- interactive screens ----------------------------------------------------
#
# Each screen sets NEXT_SCREEN and returns; run_screens loops on it. Back is a
# return value rather than a recursive call, so a user who changes their mind
# repeatedly does not grow a call stack, and every screen has one exit.
#
# These live here rather than in lib/ui.sh on purpose: ui.sh is a widget wrapper
# that knows nothing about checks, and it stays that way.
NEXT_SCREEN=""

# revert_items — checklist triples for everything still undoable: one row per
# applied tune on a schema-2 point, and one row per whole run on a schema-1 one,
# which has no per-module record to undo a single tune from.
revert_items() {
    local d ts id rest
    while IFS= read -r d; do
        [[ -n $d && -r "$d/applied.list" ]] || continue
        [[ -e "$d/reverted" ]] && continue
        ts=$(basename "$d")
        if grep -qs '^schema=2$' "$d/manifest"; then
            while read -r id; do
                [[ -n $id ]] || continue
                [[ -e "$d/modules/$id/reverted" ]] && continue
                printf '%s\n%s\n%s\n' "$ts:$id" "$id   ($ts)" OFF
            done < "$d/applied.list"
        else
            rest=$(tr '\n' ' ' < "$d/applied.list")
            printf '%s\n%s\n%s\n' "$ts:" "whole run: $rest($ts)" OFF
        fi
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -r)
}

revert_count() { local n; n=$(revert_items | wc -l); echo $(( n / 3 )); }

screen_host() {
    local -a rows=(tune "Tune this host")
    [[ $(revert_count) -gt 0 ]] && rows+=(revert "Undo a previous change")
    rows+=(quit "Quit")

    local sel
    sel=$(ui_menu "pi-tune $PI_TUNE_VERSION" "$(probe_summary)" "${rows[@]}") || {
        NEXT_SCREEN=""; return 0
    }
    case "$sel" in
        tune)   NEXT_SCREEN=status ;;
        revert) NEXT_SCREEN=revert ;;
        *)      NEXT_SCREEN="" ;;
    esac
}

# Every check and where this host stands, N/A included. The report hides those
# behind -v; here there is room, and "pi-tune considered this and it does not
# apply" is worth seeing before choosing anything.
status_text() {
    local id
    printf 'Every tuning pi-tune knows, and where this host stands.\n\n'
    while read -r id; do
        [[ -n $id ]] || continue
        printf '  [%-4s] %-22s %s\n' \
            "$(state_word "$(registry_state "$id")" "$id")" "$id" "$(registry_get "$id" title)"
    done < <(registry_ids)
    printf '\n  TUNE = can be applied     DONE = applied by pi-tune, undoable\n'
    printf '  OK   = already that way   N/A  = does not apply to this host\n'
}

screen_status() {
    local sel
    sel=$(ui_menu "Status" "$(status_text)" \
          choose "Choose what to apply" back "Back") || { NEXT_SCREEN=""; return 0; }
    case "$sel" in
        choose) NEXT_SCREEN=select ;;
        *)      NEXT_SCREEN=host ;;
    esac
}

# confirm_rows <euid> — the choices on the screen that authorises a mutating
# run. Apply is offered to root only; everyone else gets a dry run and a way
# back. Takes the id as an argument rather than reading EUID directly, because
# EUID is readonly and a rule that cannot be exercised is not a rule.
confirm_rows() {
    local -a rows=()
    [[ $1 -eq 0 ]] && rows+=(apply "Apply the changes")
    rows+=(dry "Dry run - show the diffs, write nothing" back "Back to the selection")
    printf '%s\n' "${rows[@]}"
}

screen_select() {
    local -a pending=() items=()
    mapfile -t pending < <(registry_tunables)
    mapfile -t items   < <(registry_checklist_rows)

    if [[ ${#pending[@]} -eq 0 ]]; then
        ui_msgbox "Nothing to tune" \
            "Everything that applies to this host is already in the state pi-tune wants."
        NEXT_SCREEN=host
        return 0
    fi

    ui_msgbox "Review" "$(review_text "${pending[@]}")"

    local out sel rc why body
    local -a chosen=() rows=()
    while :; do
        out=$(ui_checklist "Select" \
              "Low-risk items are pre-selected; medium and high are not." \
              "${items[@]}") || { NEXT_SCREEN=host; return 0; }
        chosen=()
        [[ -n $out ]] && mapfile -t chosen <<< "$out"
        [[ ${#chosen[@]} -eq 0 ]] && { info "nothing selected"; NEXT_SCREEN=host; return 0; }

        # Browsing needs no root; applying does. Rather than demanding root at
        # launch, the Apply row is simply absent and the body says why.
        rows=()
        mapfile -t rows < <(confirm_rows "$EUID")
        why=""
        [[ $EUID -eq 0 ]] || why="

Not running as root, so only a dry run is available here."

        body="About to apply ${#chosen[@]} change(s) on $(hostname):\n\n"
        body+="$(printf '  - %s\n' "${chosen[@]}")"
        body+="\nOriginals are backed up and can be undone.$why"

        sel=$(ui_menu "Confirm" "$body" "${rows[@]}")
        rc=$?
        # Cancel is a second thought: back to the checklist with the ticks still
        # set. Esc is leaving, and must not apply anything.
        [[ $rc -eq 1 ]] && continue
        [[ $rc -ne 0 ]] && { NEXT_SCREEN=""; return 0; }

        case "$sel" in
            apply) DRY_RUN=0; break ;;
            dry)   DRY_RUN=1; break ;;
            *)     continue ;;
        esac
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        # The diff is the whole product of a dry run, and screen_finish opens a
        # dialog over the terminal a moment after it prints - on the box it was
        # only readable afterwards, in scrollback. Capture it and hand it back
        # in a box that pages. Backslashes are doubled because whiptail expands
        # escapes in body text, and a diff carries whatever the file carries.
        local out
        out=$(apply_ids "${chosen[@]}" 2>&1)
        # shellcheck disable=SC1003  # a backslash is the literal wanted here
        local bs='\'               # a lone backslash, held in a variable so
        out=${out//"$bs"/"$bs$bs"}   # neither quoting layer can eat it
        ui_msgbox "Dry run - nothing was written" "$out"
    else
        # A real apply streams: it can prompt (the health gate) and it can take
        # a while, so it keeps the terminal rather than going into a box.
        apply_ids "${chosen[@]}"
    fi
    NEXT_SCREEN=finish
}

screen_revert() {
    if [[ $EUID -ne 0 ]]; then
        ui_msgbox "Undo needs root" \
            "Undoing a change writes to the system, so it needs root. Re-run with sudo."
        NEXT_SCREEN=host
        return 0
    fi

    local -a rows=()
    mapfile -t rows < <(revert_items)
    if [[ ${#rows[@]} -eq 0 ]]; then
        ui_msgbox "Nothing to undo" \
            "pi-tune has not applied anything on this host that is still in force."
        NEXT_SCREEN=host
        return 0
    fi

    local out body sure rc
    out=$(ui_checklist "Undo" \
          "Tick what to undo. A whole-run entry predates per-tune backups and comes back as one piece." \
          "${rows[@]}") || { NEXT_SCREEN=host; return 0; }
    [[ -n $out ]] || { NEXT_SCREEN=host; return 0; }

    local -a sel=()
    mapfile -t sel <<< "$out"
    body="About to undo ${#sel[@]} item(s):\n\n"
    body+="$(printf '  - %s\n' "${sel[@]}")"
    sure=$(ui_menu "Confirm undo" "$body" undo "Undo them" back "Back")
    rc=$?
    [[ $rc -eq 0 && $sure == undo ]] || { NEXT_SCREEN=host; return 0; }

    local tag ts id
    local -A byrun=()
    for tag in "${sel[@]}"; do
        ts=${tag%%:*}
        id=${tag#*:}
        byrun[$ts]+="$id "
    done
    for ts in "${!byrun[@]}"; do
        # Unquoted on purpose: a whole-run row carries an empty id and has to
        # expand to no arguments, which is what do_revert reads as "everything".
        # shellcheck disable=SC2086
        do_revert "$ts" ${byrun[$ts]}
    done

    # Both the registry and the applied index are stale now. Reloading the
    # registry re-runs every detect, which is the point: a tune just undone must
    # stop reading DONE on the status screen. This was impossible while the
    # registry only appended - a second scan doubled every entry.
    applied_index
    registry_load
    NEXT_SCREEN=host
}

screen_finish() {
    local body="Done."
    if [[ ${#NEEDS_MANUAL[@]} -gt 0 ]]; then
        body+="\n\nManual follow-up needed:\n"
        body+="$(printf '  - %s\n' "${NEEDS_MANUAL[@]}")"
    fi

    local -a rows=()
    if [[ $NEEDS_REBOOT -eq 1 ]]; then
        body+="\n\nA reboot is required for some changes to take effect."
        rows+=(reboot "Reboot now")
    fi
    rows+=(exit "Exit")

    local sel
    sel=$(ui_menu "Finished" "$body" "${rows[@]}") || { NEXT_SCREEN=""; return 0; }
    [[ $sel == reboot ]] && { info "rebooting"; run systemctl reboot; }
    NEXT_SCREEN=""
}

run_screens() {
    local screen=host
    while [[ -n $screen ]]; do
        NEXT_SCREEN=""
        case "$screen" in
            host)   screen_host ;;
            status) screen_status ;;
            select) screen_select ;;
            revert) screen_revert ;;
            finish) screen_finish ;;
            *)      NEXT_SCREEN="" ;;
        esac
        screen=$NEXT_SCREEN
    done
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

  --report            Audit only, non-interactive (default without a TTY)
  --apply             Audit, then offer a checklist of changes
  --dry-run           With --apply: show diffs and commands, write nothing
  --yes               Non-interactive; apply all low-risk items
  --revert TS|last    Roll back a run; --only narrows it to single tunes
  --rollbacks         List available rollback points
  --list              List all known checks and exit
  --only ID[,ID...]   Restrict to specific check IDs
  --no-tui            Force plain-text output
  --fleet h1,h2       SSH to each host and print its report
  -v, --verbose       Show N/A checks and debug output
  -h, --help          This

Backups live in $BACKUP_ROOT.
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --report)    MODE=report ;;   # explicit: never interactive
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

    applied_index
    registry_load

    case "$MODE" in
        list)
            local i
            while read -r i; do
                printf '%-26s %-8s %s\n' "$i" "[$(registry_get "$i" risk)]" "$(registry_get "$i" title)"
            done < <(registry_ids)
            ;;
        report)
            print_report
            ;;
        auto)
            # The menu is the default only when there is a terminal and a
            # backend, which is exactly ui_available. Everything else falls
            # through to the report: CI runs --report --no-tui unprivileged and
            # asserts it, and --fleet ships the tree over SSH and runs the same.
            # Neither may ever meet a dialog.
            if ui_available; then
                run_screens
            else
                print_report
            fi
            ;;
        revert)
            [[ $EUID -eq 0 ]] || die "revert needs root"
            # --only narrows a revert to single tunes, the same way it narrows
            # an apply. registry_load has already been filtered by it, so the
            # registry holds exactly the modules whose hooks should run.
            local -a rids=()
            [[ -n $ONLY ]] && IFS=',' read -ra rids <<< "$ONLY"
            do_revert "$REVERT_TS" ${rids[@]+"${rids[@]}"}
            ;;
        apply)
            [[ $EUID -eq 0 || $DRY_RUN -eq 1 ]] || die "--apply needs root (or use --dry-run)"
            print_report
            do_apply
            ;;
    esac
}

# Run only when executed, not when sourced. Six tests used to reach these
# functions by sed-deleting this line into a temp copy - a test surface made
# of a regex on the last line of the file, which pt-revert.sh had to guard
# against in case the line was ever renamed.
# An if, not a && - sourcing must return 0. As a compound the last line's
# false condition becomes the script's exit status, so a test that sources
# the driver would see rc 1 and, under set -e, stop there.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main "$@"
fi
