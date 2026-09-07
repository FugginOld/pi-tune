set -uo pipefail
cd "$1" || exit 1
. lib/util.sh
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo yes ;; *) echo no ;; esac; }

# cmdline_add is the only helper that edits /boot/firmware/cmdline.txt, where a
# malformed file costs a boot. It had no coverage at all: on pi3b-DNS1 the token
# is already present, so the dry run reports OK and the write path never runs.
# Everything here drives the real helpers against a temp file instead.
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
C_DIM=""; C_OFF=""; VERBOSE=0; DRY_RUN=0; NEEDS_REBOOT=0
BACKUP_DIR="$root/backup"

mk() { CMDLINE_TXT="$root/cmdline.txt"; printf '%s\n' "$1" > "$CMDLINE_TXT"; }

# --- 1. the append itself ----------------------------------------------------
mk 'console=tty1 root=PARTUUID=3c102112-02 rootwait'
NEEDS_REBOOT=0
cmdline_add "usbcore.autosuspend=-1"; rc=$?
chk "append returns 0"   "$rc" 0
chk "token appended"     "$(cat "$CMDLINE_TXT")" \
                         "console=tty1 root=PARTUUID=3c102112-02 rootwait usbcore.autosuspend=-1"
chk "stays one line"     "$(wc -l < "$CMDLINE_TXT")" 1
chk "reboot flagged"     "$NEEDS_REBOOT" 1

# Applying twice must not append twice - the boot arg would be duplicated.
before=$(cat "$CMDLINE_TXT")
cmdline_add "usbcore.autosuspend=-1"; rc=$?
chk "second add returns 0" "$rc" 0
chk "second add is a no-op" "$(cat "$CMDLINE_TXT")" "$before"

# --- 2. the line the token is appended to ------------------------------------
# ${line% } strips one trailing space, so the result never has a double space.
mk 'console=tty1 '
cmdline_add tok
chk "trailing space stripped" "$(cat "$CMDLINE_TXT")" "console=tty1 tok"

# grep -v '^[[:space:]]*$' | head -n1 - a leading blank line must not become the
# line that gets the token, or the real cmdline is left untouched below it.
printf '\n\nconsole=tty1\n' > "$CMDLINE_TXT"
cmdline_add tok
chk "blank lines skipped" "$(cat "$CMDLINE_TXT")" "console=tty1 tok"

# --- 3. the dot in the token is literal, not a wildcard ----------------------
# cmdline_has was `grep -qw` with no -F, which makes usbcore.autosuspend=-1 a
# regex whose dot matches any character. A box carrying an unrelated token that
# differs only at that position would report the setting as already applied.
mk 'console=tty1 usbcoreXautosuspend=-1'
cmdline_has "usbcore.autosuspend=-1" && r=yes || r=no
chk "dot matches literally only" "$r" no
cmdline_has "usbcoreXautosuspend=-1" && r=yes || r=no
chk "exact token still matches"  "$r" yes

# -w must still hold: a token embedded in a longer word is not a match.
mk 'console=tty1 xusbcore.autosuspend=-1'
cmdline_has "usbcore.autosuspend=-1" && r=yes || r=no
chk "substring is not a match" "$r" no

# --- 4. refuses to write when there is no file -------------------------------
CMDLINE_TXT=""
cmdline_add tok 2>/dev/null; rc=$?
chk "no cmdline file -> 1" "$rc" 1

# --- 5. the original is backed up before the write ---------------------------
mk 'console=tty1'
rm -rf "$BACKUP_DIR"
cmdline_add tok
chk "original backed up" \
    "$([ -f "$BACKUP_DIR/files$root/cmdline.txt" ] && echo yes || echo no)" yes
chk "backup holds the pre-write text" \
    "$(cat "$BACKUP_DIR/files$root/cmdline.txt" 2>/dev/null)" "console=tty1"

# --- 6. dry run writes nothing ----------------------------------------------
mk 'console=tty1'
before=$(cat "$CMDLINE_TXT")
DRY_RUN=1
out=$(cmdline_add tok 2>&1); rc=$?
DRY_RUN=0
chk "dry run returns 0"      "$rc" 0
chk "dry run wrote nothing"  "$(cat "$CMDLINE_TXT")" "$before"
chk "dry run showed the diff" "$(has x "$out" '+console=tty1 tok')" yes

exit $fail
