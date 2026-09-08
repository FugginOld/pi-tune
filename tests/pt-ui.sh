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

# These two were separated by their different fixed heights - 15 lines fit an
# 18-row yesno and not a 22-row msgbox. Both size to their content now, so that
# distinction is gone by design and asserting it would be asserting the bug.
# What must hold instead: given room neither hints, and on a screen too short
# for the body both do. An implementation ignoring the terminal passes the
# first pair and fails the second, which is what makes the pair worth having.
mid=$(printf 'l\n%.0s' $(seq 1 15))
LINES=58
seen=""; ui_msgbox "review" "$mid"
chk "roomy screen: msgbox fits"  "$(has x "$seen" 'PgDn for more')" no
seen=""; ui_yesno "Confirm" "$mid" A B
chk "roomy screen: yesno fits"   "$(has x "$seen" 'PgDn for more')" no
LINES=14
seen=""; ui_msgbox "review" "$mid"
chk "short screen: msgbox hints" "$(has x "$seen" 'PgDn for more')" yes
seen=""; ui_yesno "Confirm" "$mid" A B
chk "short screen: yesno hints"  "$(has x "$seen" 'PgDn for more')" yes

# The boundary, stated against a known screen rather than a constant box: a
# 20-row terminal gives an 18-row msgbox, 6 of which are chrome, so 12 lines
# fit and 13 do not. LINES is pinned because otherwise this asserts whatever
# terminal CI happens to run under.
LINES=20
twelve=$(printf 'l\n%.0s' $(seq 1 12))
seen=""; ui_msgbox "review" "$twelve"
chk "12 lines fit"          "$(has x "$seen" 'PgDn for more')" no
seen=""; ui_msgbox "review" "$twelve\nl"
chk "13 lines do not"       "$(has x "$seen" 'PgDn for more')" yes

# Wrapping counts, not just newlines: one long line can overflow on its own.
seen=""; ui_msgbox "review" "$(head -c 2000 /dev/zero | tr '\0' 'x')"
chk "wrapped long line counts" "$(has x "$seen" 'PgDn for more')" yes
unset LINES

# The real title must survive the suffix.
chk "title kept"            "$(has x "$seen" 'review')" yes

# --- ui_menu -----------------------------------------------------------------
# Probed on whiptail before this was written: tag on stderr, rc 0 for any
# selection, 1 for Cancel, 255 for Esc. The stub writes to stderr because that
# is where the real thing puts it, and ui_menu's 3>&1 1>&2 2>&3 is what turns
# that into stdout for the caller.
have() { [[ $1 == whiptail ]]; }
UI_BIN=""; UI_SCROLL=(); ui_pick_backend
argf=$(mktemp); trap 'rm -f "$argf"' EXIT
# ui_menu runs its backend inside $( ), so a stub assigning to a variable would
# be writing in a subshell and the assertion would read an empty string and
# agree with anything. Record the arguments to a file instead.
args() { cat "$argf"; }
whiptail() { printf '%s
' "$*" > "$argf"; echo "chosen" >&2; return 0; }

: > "$argf"; got=$(ui_menu "Confirm" "body" a "row a" b "row b"); rc=$?
chk "menu returns the tag"    "$got"                                  chosen
chk "menu rc 0 on a choice"   "$rc"                                   0
chk "menu passes --menu"      "$(has x "$(args)" '--menu')"          yes
# 10 is the floor, not the old constant 22: one line of body and two rows of
# list does not justify a 22-row window on any screen.
chk "list height = item count" "$(has x "$(args)" 'body 10 78 2')"    yes

# rc has to survive: Cancel means go back, Esc means abort, and the confirm
# screen is the one place that distinction authorises a mutating run.
whiptail() { return 1; }
ui_menu "Confirm" "body" a "row a" >/dev/null; chk "Cancel gives 1"   "$?" 1
whiptail() { return 255; }
ui_menu "Confirm" "body" a "row a" >/dev/null; chk "Esc gives 255"    "$?" 255
# Nothing may reach stdout when the user did not choose - a caller reading the
# tag must get an empty string, not a stale one.
whiptail() { printf '%s
' "$*" > "$argf"; echo "chosen" >&2; return 1; }
got=$(ui_menu "Confirm" "body" a "row a"); chk "no tag on Cancel"     "$got" ""

# The list shrinks the body's room, so the overflow budget moves with it.
whiptail() { printf '%s
' "$*" > "$argf"; echo "chosen" >&2; return 0; }
short=$(printf 'l
%.0s' $(seq 1 12))
: > "$argf"; ui_menu "m" "$short" a "1" b "2" >/dev/null
chk "12 lines fit a 2-row menu"  "$(has x "$(args)" 'PgDn for more')" no
: > "$argf"; ui_menu "m" "$short" a "1" b "2" c "3" d "4" e "5" f "6" g "7" >/dev/null
chk "same text overflows a 7-row menu" "$(has x "$(args)" 'PgDn for more')" yes

# --- ui_menu plain-text fallback --------------------------------------------
UI_BIN=""; UI_SCROLL=()
got=$(printf '2\n' | ui_menu "t" "pick" a "row a" b "row b" 2>/dev/null); rc=$?
chk "fallback returns the tag" "$got"                                 b
chk "fallback rc 0"            "$rc"                                  0
got=$(printf '\n' | ui_menu "t" "pick" a "row a" 2>/dev/null); rc=$?
chk "Enter means go back"      "$rc"                                  1
chk "and prints no tag"        "$got"                                 ""
printf '9\n' | ui_menu "t" "pick" a "row a" >/dev/null 2>&1
chk "out of range is a no"     "$?"                                   1
ui_menu "t" "pick" a "row a" >/dev/null 2>&1 < /dev/null
chk "EOF aborts, not go-back"  "$?"                                   255
# The escape must expand here too, or the fallback shows a literal backslash-n.
out=$(printf '1\n' | ui_menu "t" "one\ntwo" a "row a" 2>&1 >/dev/null)
chk "fallback expands \n"     "$(has x "$out" 'one\ntwo')"           no

# --- escapes never reach a dialog body --------------------------------------
# The dry-run screen captures apply_ids, whose colour is decided once at load
# from [[ -t 1 ]] - so a run started on a tty hands this text ^[[32m, which
# whiptail draws literally. Stripping lives in ui_msgbox because no caller
# wants an escape in a box.
esc=$(printf '\033')
out=$(ui_msgbox "t" "$(printf '\033[32m==>\033[0m applying x\033[2m ok\033[0m')" 2>&1)
chk "escapes stripped"        "$(printf '%s\n' "$out" | grep -c "$esc")"  0
chk "the words survive"       "$(has x "$out" '==> applying x ok')"       yes
# Only the colour form goes. A backslash is content - a diff carries whatever
# the file carries - and must come out the other side.
out=$(ui_msgbox "t" 'C:\path and a lone \ backslash' 2>&1)
chk "backslashes kept"        "$(has x "$out" 'a lone \ backslash')"      yes

# --- box geometry -----------------------------------------------------------
# Every dialog was a constant 22 rows. On pi3b-DNS1, a 58-row terminal, the
# status table is 17 lines and drew 13 of them - pcie-gen3 sat below a fold
# with nothing on screen saying a twelfth check existed. Height now follows
# the content and stops at the screen.
long=$(printf 'line %d\n' $(seq 1 17))
short=$(printf 'one\ntwo\n')

LINES=58
chk "grows with content"      "$(ui_box_height "$long" 8)"    25
# The old constant is not a floor either: a short body must not draw dead space.
chk "short body stays small"  "$(ui_box_height "$short" 6)"   10
# ...but never smaller than a usable box, however little text there is.
chk "never below the minimum" "$(ui_box_height "x" 0)"        10

# A tall body on a short screen clamps and scrolls, rather than drawing a box
# taller than the terminal - which is what would hide content with no scrollbar.
LINES=20
chk "clamps to the screen"    "$(ui_box_height "$long" 8)"    18
chk "clamp beats content"     "$(( $(ui_box_height "$long" 8) < 25 ? 1 : 0 ))" 1

# With room, the status table stops overflowing at all - so no PgDn hint.
LINES=58
h=$(ui_box_height "$long" 8)
chk "no overflow when sized"  "$(ui_overflows "$long" $(( h - 8 )) 74 && echo yes || echo no)" no
# Same content on the old constant would have overflowed. This is the control:
# without it the assertion above passes for a box of any size.
chk "and did on the old 22"   "$(ui_overflows "$long" $(( 22 - 8 )) 74 && echo yes || echo no)" yes
unset LINES

exit $fail
