set -uo pipefail
cd "$1" || exit 1
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo yes ;; *) echo no ;; esac; }

# The screens themselves need a terminal, so what is testable here is the logic
# they are made of: which rows get offered, what the status table says, and that
# the loop goes where NEXT_SCREEN points.
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT

export PI_TUNE_BACKUP_ROOT="$root/backups"
NO_TUI=1
# shellcheck disable=SC1090
. ./pi-tune.sh
NO_TUI=1; VERBOSE=0; ONLY=""

# --- 1. Apply is offered to root only ---------------------------------------
# The one rule on this screen that matters: browsing needs no root, applying
# does. EUID is readonly, which is why confirm_rows takes it as an argument -
# a rule that cannot be exercised is not a rule.
chk "root is offered Apply"     "$(has x "$(confirm_rows 0)" 'apply')"   yes
chk "non-root is not"           "$(has x "$(confirm_rows 1000)" 'apply')" no
chk "non-root still gets dry"   "$(has x "$(confirm_rows 1000)" 'dry')"  yes
chk "non-root still gets back"  "$(has x "$(confirm_rows 1000)" 'back')" yes
# Rows are tag/label pairs; an odd count would misalign every label by one.
chk "root rows are pairs"       "$(( $(confirm_rows 0 | wc -l) % 2 ))"   0
chk "non-root rows are pairs"   "$(( $(confirm_rows 1000 | wc -l) % 2 ))" 0

# --- 2. what can still be undone --------------------------------------------
mk2() {                                  # mk2 <ts> <id>... — a schema-2 point
    local ts=$1; shift
    mkdir -p "$PI_TUNE_BACKUP_ROOT/$ts"
    printf 'schema=2\n' > "$PI_TUNE_BACKUP_ROOT/$ts/manifest"
    printf '%s\n' "$@" > "$PI_TUNE_BACKUP_ROOT/$ts/applied.list"
    local id
    for id in "$@"; do mkdir -p "$PI_TUNE_BACKUP_ROOT/$ts/modules/$id"; done
}
mk1() {                                  # mk1 <ts> <id>... — a pre-schema-2 one
    local ts=$1; shift
    mkdir -p "$PI_TUNE_BACKUP_ROOT/$ts"
    printf 'host=t\n' > "$PI_TUNE_BACKUP_ROOT/$ts/manifest"
    printf '%s\n' "$@" > "$PI_TUNE_BACKUP_ROOT/$ts/applied.list"
}
BACKUP_ROOT="$PI_TUNE_BACKUP_ROOT"

mk2 20260101-000000 alpha beta
chk "one row per tune"          "$(( $(revert_items | wc -l) / 3 ))"     2
chk "tag carries run and tune"  "$(has x "$(revert_items)" '20260101-000000:alpha')" yes
chk "count agrees with rows"    "$(revert_count)"                        2

# A tune already undone is not offered again.
touch "$PI_TUNE_BACKUP_ROOT/20260101-000000/modules/alpha/reverted"
chk "reverted tune drops out"   "$(has x "$(revert_items)" ':alpha')"    no
chk "its sibling remains"       "$(has x "$(revert_items)" ':beta')"     yes
chk "count follows"             "$(revert_count)"                        1

# A schema-1 point has no per-module record, so it is one row for the whole run.
mk1 20260102-000000 gamma delta
chk "v1 is a single row"        "$(( $(revert_items | wc -l) / 3 ))"     2
chk "v1 tag has no tune id"     "$(has x "$(revert_items)" '20260102-000000:')" yes
chk "v1 row says whole run"     "$(has x "$(revert_items)" 'whole run')" yes
# The empty id is load-bearing: unquoted it must expand to no arguments, which
# is what do_revert reads as "everything in this run".
tag=$(revert_items | grep '^20260102-000000:')
chk "v1 id half is empty"       "${tag#*:}"                              ""

# A whole run undone leaves nothing to offer.
touch "$PI_TUNE_BACKUP_ROOT/20260102-000000/reverted"
chk "reverted run drops out"    "$(has x "$(revert_items)" '20260102')"  no

# --- 3. the status table ----------------------------------------------------
C_ID=(a b c d); C_TITLE=(ta tb tc td); C_RISK=(low low low low)
C_STATE=(0 1 2 0); C_FILE=(f f f f); C_WHY=(w w w w); C_IMPACT=(i i i i)
APPLIED=(["d"]=20260101-000000)   # quoted: an unquoted subscript reads as arithmetic (SC2154)
# Force colour on. Off a tty util.sh leaves C_* empty, so state_label would emit
# no escapes either and the assertion below could not fail - it would agree with
# a coloured table rather than rule one out.
C_GRN=$'[32m'; C_YEL=$'[33m'; C_DIM=$'[2m'; C_OFF=$'[0m'
out=$(status_text)
chk "shows OK"                  "$(has x "$out" '[OK  ]')"               yes
chk "shows TUNE"                "$(has x "$out" '[TUNE]')"               yes
chk "shows N/A"                 "$(has x "$out" '[N/A ]')"               yes
chk "shows DONE for applied"    "$(has x "$out" '[DONE]')"               yes
# N/A is hidden behind -v in the report; the status screen has room for it.
chk "N/A is not hidden here"    "$(has x "$out" 'c')"                    yes
# An escape sequence inside a whiptail body renders as garbage, not as colour.
chk "no colour escapes"         "$(printf '%s' "$out" | grep -c $'\033')" 0

# --- 4. the screen loop -----------------------------------------------------
# Back is a return value, not recursion, so the path is whatever NEXT_SCREEN
# says and a user changing their mind cannot grow a stack.
seen=""
screen_host()   { seen+="host "; NEXT_SCREEN=$host_next; }
screen_status() { seen+="status "; NEXT_SCREEN=select; }
screen_select() { seen+="select "; NEXT_SCREEN=finish; }
screen_finish() { seen+="finish "; NEXT_SCREEN=""; }
screen_revert() { seen+="revert "; NEXT_SCREEN=host; }

host_next=status; seen=""; run_screens
chk "walks the tune path"       "$seen"          "host status select finish "

# Quit from the first screen visits nothing else.
host_next=""; seen=""; run_screens
chk "quit stops immediately"    "$seen"          "host "

# Undo returns to host, and host can then quit - the loop must not recurse.
host_next=revert; seen=""
screen_revert() { seen+="revert "; host_next=""; NEXT_SCREEN=host; }
run_screens
chk "undo returns to host"      "$seen"          "host revert host "

# An unknown screen name ends the loop rather than spinning.
host_next=nonsense; seen=""; run_screens
chk "unknown name terminates"   "$seen"          "host "

exit $fail
