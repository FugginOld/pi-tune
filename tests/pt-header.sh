set -uo pipefail
cd "$1" || exit 1
. lib/util.sh; . lib/ui.sh
NO_TUI=1; ui_init

# Stand in for a real probe.
PI_MODEL="Raspberry Pi 3 Model B Plus Rev 1.4"
DISTRO_PRETTY="Debian GNU/Linux 13 (trixie)"
RAM_MB=905; CPU_COUNT=4; ROOT_SRC=/dev/sda2; ROOT_FSTYPE=ext4
ROOT_MEDIA="USB-attached disk"

fmt='Host:   %s — %s\nSystem: %s, %s MB RAM, %s cores\nRoot:   %s (%s)%s\nLow-risk items are pre-selected; medium and high are not.'
printf -v header "$fmt" \
    "testbox" "$PI_MODEL" "$DISTRO_PRETTY" "$RAM_MB" "$CPU_COUNT" "$ROOT_SRC" "$ROOT_FSTYPE" \
    "${ROOT_MEDIA:+ [$ROOT_MEDIA]}"

out=$(echo "" | ui_checklist "pi-tune 1.0.0" "$header" \
      journald-cap "[low] Cap systemd journal size" ON \
      docker-log-caps "[medium] Cap Docker container log size" OFF 2>/tmp/hdr.err)

echo "--- rendered header ---"; cat /tmp/hdr.err; echo "--- selected ---"; echo "$out"

fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
e=$(cat /tmp/hdr.err)

if [[ $e == *'\n'* ]]; then echo "FAIL literal backslash-n in output"; fail=1; else echo "ok   no literal backslash-n"; fi
chk "host line present"   "$(grep -c '^Host:   testbox — Raspberry Pi 3' /tmp/hdr.err)" 1
chk "system line present" "$(grep -c '^System: Debian GNU/Linux 13 (trixie), 905 MB RAM, 4 cores$' /tmp/hdr.err)" 1
# The header must carry the medium: it is what makes usb-autosuspend apply, and
# this screen is what is on screen while the boxes are ticked.
chk "root line has media" "$(grep -c '^Root:   /dev/sda2 (ext4) \[USB-attached disk\]$' /tmp/hdr.err)" 1
# The format string above is a copy of do_apply's. Assert it still matches, or
# this test passes while checking a header the tool no longer produces.
chk "format mirrors do_apply" "$(grep -cF "$fmt" pi-tune.sh)" 1
chk "header is 4 lines"   "$(sed -n '/^Host:/,/^Low-risk/p' /tmp/hdr.err | wc -l)" 4
# widest line must fit whiptail's 78-column box (minus ~6 for borders/padding)
chk "fits in 72 cols"     "$(awk '{ if (length($0) > 72) n++ } END { print n+0 }' /tmp/hdr.err)" 0
# Enter with no input must still take the ON default
chk "default selection"   "$out" journald-cap

rm -f /tmp/hdr.err
exit $fail
