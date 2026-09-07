set -uo pipefail
cd "$1" || exit 1
. lib/util.sh; . lib/ui.sh
NO_TUI=1; ui_init                      # force the plain-text fallback
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo yes ;; *) echo no ;; esac; }
fail=0

txt="About to apply 2 change(s):\n\n  - zram-swap\n  - wifi-powersave\n\nOriginals are backed up."
out=$(echo n | ui_yesno "Confirm" "$txt" 2>&1 || true)

echo "--- rendered ---"; echo "$out"; echo "--- /rendered ---"

fail=0
# Literal backslash-n must not survive into the rendered output.
if [[ $out == *'\n'* ]]; then echo "FAIL literal backslash-n present"; fail=1
else echo "ok   no literal backslash-n"; fi

# The two items must land on their own lines.
lines=$(grep -c '^  - ' <<<"$out")
if [[ $lines -eq 2 ]]; then echo "ok   2 items on separate lines"; else echo "FAIL items on $lines lines"; fail=1; fi

# Discrimination: the pre-fix implementation must fail this same assertion.
old_yesno() { printf '\n%s\n%s [y/N] ' "$2" "$1" >&2; }
old=$(old_yesno "Confirm" "$txt" 2>&1)
if [[ $old == *'\n'* ]]; then echo "ok   old %s impl fails the check (test discriminates)"
else echo "FAIL test does not discriminate — old impl passes too"; fail=1; fi

# --- scroll flag per backend -------------------------------------------------
# Both backends clip text taller than the box with no bar, no marker and no
# error. They spell the flag differently, and --scrolltext is an unknown option
# to dialog rather than a harmless no-op, so one spelling for both breaks the
# other outright. Only whiptail ships on Raspberry Pi OS, so the dialog pairing
# has no box here to catch it - this is the only thing that will.
seen=""
whiptail() { seen="$*"; return 0; }
dialog()   { seen="$*"; return 0; }

for bin in whiptail dialog; do
    case $bin in whiptail) want=--scrolltext ;; *) want=--scrollbar ;; esac

    # ui_pick_backend probes with have(); answer for this backend only, then let
    # it choose - the pairing is what is under test, not a value set by hand.
    eval "have() { [[ \$1 == $bin ]]; }"
    UI_BIN=""; UI_SCROLL=()
    ui_pick_backend
    chk "$bin selected"        "$UI_BIN" "$bin"
    chk "$bin pairs $want"     "${UI_SCROLL[*]}" "$want"

    # Overflowing text, since the flag is only sent when there is something to
    # scroll - the point here is that each backend gets its own spelling.
    over=$(printf 'line\n%.0s' $(seq 1 40))
    seen=""; ui_msgbox "t" "$over"
    chk "$bin msgbox sends it" "$(has x "$seen" "$want")" yes

    seen=""; ui_yesno "t" "$over" "Apply" "Back"
    chk "$bin yesno sends it"  "$(has x "$seen" "$want")" yes
    # The relabelled buttons must survive alongside the new flag.
    chk "$bin yesno keeps labels" "$(has x "$seen" '--yes-button Apply')" yes
done

# Neither backend installed: no flag to pass, and no TUI to pass it to.
have() { return 1; }
UI_BIN=whiptail; UI_SCROLL=(--scrolltext)
ui_pick_backend
chk "no backend clears UI_BIN"  "$UI_BIN" ""
chk "no backend clears flag"    "${UI_SCROLL[*]}" ""

# --- overflow hint -----------------------------------------------------------
# newt draws no scrollbar even with --scrolltext, so a long review screen looks
# truncated when it is only scrolled to the top. The title has to say so, and
# only when there is actually more than the box shows.
have() { [[ $1 == whiptail ]]; }
UI_BIN=""; UI_SCROLL=(); ui_pick_backend

long=$(printf 'line\n%.0s' $(seq 1 40))
seen=""; ui_msgbox "review" "$long"
chk "long text flags PgDn"  "$(has x "$seen" 'PgDn for more')" yes

seen=""; ui_msgbox "review" "short body"
chk "short text does not"   "$(has x "$seen" 'PgDn for more')" no

# The bar appears only when content fits and is absent when it overflows, so on
# a screen that fits the flag draws a bar promising more that is not there.
seen=""; ui_msgbox "review" "short body"
chk "fits: no scroll flag"  "$(has x "$seen" '--scrolltext')" no
seen=""; ui_msgbox "review" "$long"
chk "overflows: scroll flag" "$(has x "$seen" '--scrolltext')" yes

# ui_yesno measures its own smaller box rather than borrowing msgbox's numbers.
seen=""; ui_yesno "Confirm" "two\nlines" Apply Back
chk "yesno fits: no flag"   "$(has x "$seen" '--scrolltext')" no
chk "yesno fits: no hint"   "$(has x "$seen" 'PgDn for more')" no
seen=""; ui_yesno "Confirm" "$long" Apply Back
chk "yesno overflows: flag" "$(has x "$seen" '--scrolltext')" yes
chk "yesno overflows: hint" "$(has x "$seen" 'PgDn for more')" yes
chk "yesno keeps buttons"   "$(has x "$seen" '--yes-button Apply')" yes

# 15 wrapped lines fit an 18-line yesno box but not... nothing: both boxes must
# use their own threshold, so a text between the two sizes separates them.
mid=$(printf 'l\n%.0s' $(seq 1 15))
seen=""; ui_msgbox "review" "$mid"; m=$(has x "$seen" 'PgDn for more')
seen=""; ui_yesno "Confirm" "$mid" A B; y=$(has x "$seen" 'PgDn for more')
chk "15 lines: msgbox fits"  "$m" no
chk "15 lines: yesno does not" "$y" yes

# The boundary: 16 lines fit, 17 do not.
fit=$(printf 'l\n%.0s' $(seq 1 15))l
seen=""; ui_msgbox "review" "$fit"
chk "16 lines fit"          "$(has x "$seen" 'PgDn for more')" no
seen=""; ui_msgbox "review" "$fit\nl\nl"
chk "18 lines do not"       "$(has x "$seen" 'PgDn for more')" yes

# Wrapping counts, not just newlines: one long line can overflow on its own.
seen=""; ui_msgbox "review" "$(head -c 2000 /dev/zero | tr '\0' 'x')"
chk "wrapped long line counts" "$(has x "$seen" 'PgDn for more')" yes

# The real title must survive the suffix.
chk "title kept"            "$(has x "$seen" 'review')" yes

exit $fail
