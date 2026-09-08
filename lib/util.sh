#!/usr/bin/env bash
# shellcheck disable=SC2034  # several globals are consumed by dynamically sourced check modules
# lib/util.sh — logging, dry-run plumbing, backup/restore helpers.
# Sourced by pi-tune.sh and by every check module.

# --- output -----------------------------------------------------------------

if [[ -t 2 ]]; then
    C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
    C_DIM=$'\033[2m';  C_BLD=$'\033[1m';  C_OFF=$'\033[0m'
else
    C_RED=''; C_YEL=''; C_GRN=''; C_DIM=''; C_BLD=''; C_OFF=''
fi

info() { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; }
warn() { printf '%swarn:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

dbg() { [[ ${VERBOSE:-0} -eq 1 ]] && printf '%s  . %s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; return 0; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- state shared with the driver -------------------------------------------

: "${DRY_RUN:=0}"
: "${BACKUP_DIR:=}"
NEEDS_REBOOT=0
NEEDS_MANUAL=()

require_reboot() { NEEDS_REBOOT=1; }
require_manual() { NEEDS_MANUAL+=("$1"); }

# --- command execution ------------------------------------------------------

# run <cmd...> — execute, or print under --dry-run.
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s    would run:%s %s\n' "$C_DIM" "$C_OFF" "$*" >&2
        return 0
    fi
    dbg "run: $*"
    "$@"
}

# --- backups ----------------------------------------------------------------

# backup_file <path> — snapshot a file into BACKUP_DIR, preserving its
# absolute path so revert can restore it blind.
backup_file() {
    local src=$1 dest
    [[ -e $src ]] || return 0
    [[ -n $BACKUP_DIR ]] || return 0

    dest="$BACKUP_DIR/files$src"
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s    would back up:%s %s\n' "$C_DIM" "$C_OFF" "$src" >&2
        return 0
    fi
    mkdir -p "$(dirname "$dest")" || return 1
    cp -a "$src" "$dest" || return 1
    dbg "backed up $src"
}

# record_absent <path> — note that a path did NOT exist before we ran, so
# revert deletes it rather than restoring nothing.
record_absent() {
    local p=$1
    [[ -n $BACKUP_DIR ]] || return 0
    [[ -e $p ]] && return 0
    [[ $DRY_RUN -eq 1 ]] && return 0
    mkdir -p "$BACKUP_DIR"
    printf '%s\n' "$p" >> "$BACKUP_DIR/created.list"
}

# record_new_dirs <path> — note the directories that do not exist yet but will
# be created to hold <path>, so revert can rmdir the ones we made. Recorded
# deepest-first, which is the order revert has to remove them in.
record_new_dirs() {
    local d; d=$(dirname "$1")
    [[ -n $BACKUP_DIR ]] || return 0
    [[ $DRY_RUN -eq 1 ]] && return 0
    local -a new=()
    while [[ -n $d && $d != / && $d != . && ! -d $d ]]; do
        new+=("$d")
        d=$(dirname "$d")
    done
    [[ ${#new[@]} -eq 0 ]] && return 0
    mkdir -p "$BACKUP_DIR"
    printf '%s\n' "${new[@]}" >> "$BACKUP_DIR/created.dirs"
}

# install_file <src> <dest> [mode] — back up dest, then replace it with src.
# Under --dry-run this prints a unified diff instead, which doubles as the
# preview mechanism.
install_file() {
    local src=$1 dest=$2 mode=${3:-}

    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s    diff for %s:%s\n' "$C_DIM" "$dest" "$C_OFF" >&2
        if [[ -e $dest ]]; then
            diff -u "$dest" "$src" >&2 || true
        else
            printf '%s    (new file)%s\n' "$C_DIM" "$C_OFF" >&2
            sed 's/^/    | /' "$src" >&2
        fi
        rm -f "$src"
        return 0
    fi

    record_absent "$dest"
    record_new_dirs "$dest"
    backup_file "$dest" || { err "backup of $dest failed; refusing to write"; rm -f "$src"; return 1; }
    mkdir -p "$(dirname "$dest")"
    cat "$src" > "$dest" || { rm -f "$src"; return 1; }
    rm -f "$src"
    [[ -n $mode ]] && chmod "$mode" "$dest"
    return 0
}

# write_drop_in <path> <<'EOF' ... EOF — create a config drop-in from stdin.
write_drop_in() {
    local dest=$1 tmp
    tmp=$(mktemp) || return 1
    cat > "$tmp"
    install_file "$tmp" "$dest" 0644
}

# --- systemd ----------------------------------------------------------------

unit_exists() { systemctl list-unit-files --no-legend "$1" 2>/dev/null | grep -q .; }
unit_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
unit_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }

# sysctl_drop_in <name> <key=value>...
sysctl_drop_in() {
    local name=$1; shift
    local tmp; tmp=$(mktemp) || return 1
    {
        echo "# written by pi-tune"
        printf '%s\n' "$@"
    } > "$tmp"
    # What these keys read right now. Removing the drop-in on revert does not
    # put them back: the kernel keeps the running value and, once our file is
    # gone, no file mentions the key for `sysctl --system` to re-read. Undoing
    # zram-swap on pi3b-DNS1 left vm.swappiness=100 behind exactly this way.
    if [[ ${DRY_RUN:-0} -eq 0 && -d ${BACKUP_DIR:-} ]]; then
        local kv key val
        for kv in "$@"; do
            key=${kv%%=*}
            val=$(sysctl -n "$key" 2>/dev/null) || continue
            printf '%s=%s
' "$key" "$val" >> "$BACKUP_DIR/sysctl.pre"
        done
    fi

    install_file "$tmp" "/etc/sysctl.d/$name" 0644 || return 1
    run sysctl --quiet --system
}

# --- kernel cmdline ---------------------------------------------------------

# cmdline_has <token>
cmdline_has() {
    [[ -n ${CMDLINE_TXT:-} && -r ${CMDLINE_TXT:-} ]] || return 1
    # Compare tokens exactly rather than grepping for one. Neither grep route is
    # safe here: without -F the dot in usbcore.autosuspend=-1 is a wildcard, and
    # -w does not reliably supply the boundary (grep -wF matched that token
    # inside xusbcore.autosuspend=-1). The kernel command line is whitespace-
    # separated tokens, so split it and compare - no regex, no grep-build quirks.
    local -a toks; local tok
    while read -r -a toks; do
        for tok in ${toks[@]+"${toks[@]}"}; do
            [[ $tok == "$1" ]] && return 0
        done
    done < "$CMDLINE_TXT"
    return 1
}

# cmdline_add <token> — append a token to the single-line firmware cmdline.
cmdline_add() {
    local token=$1 tmp line
    [[ -n ${CMDLINE_TXT:-} && -r $CMDLINE_TXT ]] || { warn "no cmdline file found"; return 1; }
    cmdline_has "$token" && return 0

    line=$(grep -v '^[[:space:]]*$' "$CMDLINE_TXT" | head -n1)
    tmp=$(mktemp) || return 1
    printf '%s %s\n' "${line% }" "$token" > "$tmp"
    install_file "$tmp" "$CMDLINE_TXT" 0644 || return 1
    require_reboot
}

# config_txt_set <key=value> — set or append a line in config.txt.
config_txt_set() {
    local kv=$1 key=${1%%=*} tmp
    [[ -n ${CONFIG_TXT:-} && -r $CONFIG_TXT ]] || { warn "no config.txt found"; return 1; }
    tmp=$(mktemp) || return 1
    if grep -qE "^[[:space:]]*#?[[:space:]]*${key}=" "$CONFIG_TXT"; then
        sed -E "s|^[[:space:]]*#?[[:space:]]*${key}=.*|${kv}|" "$CONFIG_TXT" > "$tmp"
    else
        { cat "$CONFIG_TXT"; echo; echo "# added by pi-tune"; echo "$kv"; } > "$tmp"
    fi
    install_file "$tmp" "$CONFIG_TXT" 0644 || return 1
    require_reboot
}

config_txt_has() {
    [[ -n ${CONFIG_TXT:-} && -r ${CONFIG_TXT:-} ]] || return 1
    grep -qE "^[[:space:]]*$1" "$CONFIG_TXT"
}

# --- packages ---------------------------------------------------------------

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed'; }

_apt_get() { DEBIAN_FRONTEND=noninteractive apt-get "$@" -o Dpkg::Use-Pty=0 >/dev/null 2>&1; }

# pkg_install <pkg>... — install what's missing. Packages are never removed on
# revert; the checks that install one raise a require_manual note instead.
pkg_install() {
    local p
    for p in "$@"; do
        pkg_installed "$p" && continue
        if [[ $DRY_RUN -eq 1 ]]; then
            printf '%s    would install:%s %s\n' "$C_DIM" "$C_OFF" "$p" >&2
            continue
        fi
        _apt_get install -y "$p" && continue
        # A box that has been off for a while has stale lists and 404s here.
        # Refresh only on failure: an unconditional update costs every apply a
        # network round trip, including the ones that install nothing.
        warn "installing $p failed; refreshing package lists and retrying"
        _apt_get update
        _apt_get install -y "$p" || { err "apt-get install $p failed"; return 1; }
    done
    return 0
}
