set -uo pipefail
cd "$1" || exit 1
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# The registry used to be seven arrays indexed by position from fourteen places.
# What is asserted here is the interface that replaced them: ids in load order,
# fields fetched by id, and an unknown id refused rather than answered with a
# neighbour's value. That last one is the whole point - under the positional
# version a skew returned the wrong module's file under the right label, and
# nothing could tell.
DRY_RUN=0; VERBOSE=0; NO_TUI=1; ONLY=""; ASSUME_YES=0
. ./pi-tune.sh

root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
cdir="$root/checks"; mkdir -p "$cdir"
mk() {                                   # mk <n> <id> <risk> <detect-rc>
    cat > "$cdir/$1-$2.sh" <<EOF
CHECK_ID="$2"; CHECK_TITLE="title of $2"; CHECK_RISK="$3"
check_detect() { return $4; }
check_why()    { echo "why $2"; }
check_impact() { echo "impact $2"; }
EOF
}
mk 10 alpha low    1
mk 20 beta  medium 0
mk 30 gamma high   2
mk 40 delta low    1
CHECK_DIR="$cdir"

# --- 1. load and order ------------------------------------------------------
registry_load
chk "loads every module"      "$(registry_ids | wc -l)"                 4
chk "keeps load order"        "$(registry_ids | tr '\n' ' ')"           "alpha beta gamma delta "

# Loading twice is a refresh, not a doubling. The append-only version is why a
# screen could not re-read the world after changing it.
registry_load
chk "second load replaces"    "$(registry_ids | wc -l)"                 4

# --- 2. fields come back by id ----------------------------------------------
chk "title by id"             "$(registry_get beta title)"              "title of beta"
chk "risk by id"              "$(registry_get gamma risk)"              high
chk "why by id"               "$(registry_get alpha why)"               "why alpha"
chk "impact by id"            "$(registry_get delta impact)"            "impact delta"
chk "file by id"              "$(basename "$(registry_get beta file)")" 20-beta.sh
chk "state by id"             "$(registry_state gamma)"                 2

# The file field is the one that mattered: apply_ids sources whatever comes back
# here, so a wrong answer runs a different tuning under the requested name.
chk "file matches the id"     "$(basename "$(registry_get delta file)")" 40-delta.sh

# --- 3. an unknown id is refused --------------------------------------------
chk "unknown id rc"           "$(registry_get nosuch title >/dev/null 2>&1; echo $?)" 1
chk "unknown id prints nothing" "$(registry_get nosuch title 2>/dev/null)"            ""
chk "unknown state rc"        "$(registry_state nosuch >/dev/null 2>&1; echo $?)"     1
chk "registry_has knows"      "$(registry_has beta && echo yes || echo no)"           yes
chk "registry_has refuses"    "$(registry_has nosuch && echo yes || echo no)"         no
# An unknown field is refused too, so a typo'd caller fails instead of reading
# as an empty title.
chk "unknown field rc"        "$(registry_get beta nosuchfield >/dev/null 2>&1; echo $?)" 1

# --- 4. tunables and the checklist rows -------------------------------------
# Only detect==1 is offered. beta is satisfied, gamma does not apply here.
chk "tunables are state 1"    "$(registry_tunables | tr '\n' ' ')"      "alpha delta "
chk "rows are triples"        "$(( $(registry_checklist_rows | wc -l) % 3 ))"  0
# With single-line titles that check is a tautology - the printf structurally
# emits 3n lines. A title carrying a newline is what can break the stride, and
# the module author picks the title.
cat > "$cdir/50-multi.sh" <<'MEOF'
CHECK_ID="multi"; CHECK_RISK="low"
CHECK_TITLE="first line
second line"
check_detect() { return 1; }
check_why()    { echo why; }
check_impact() { echo impact; }
MEOF
registry_load
chk "newline title keeps stride" "$(( $(registry_checklist_rows | wc -l) % 3 ))" 0
chk "one row per tunable still"  "$(( $(registry_checklist_rows | wc -l) / 3 ))" 3
# The failure this prevents: the following item's tag read as a stray "ON".
mapfile -t rows < <(registry_checklist_rows)
chk "tags land on the stride"    "${rows[0]} ${rows[3]} ${rows[6]}"             "alpha delta multi"
rm -f "$cdir/50-multi.sh"
registry_load
chk "one row per tunable"     "$(( $(registry_checklist_rows | wc -l) / 3 ))"  2
chk "row carries the risk"    "$(registry_checklist_rows | sed -n '2p')"       "[low] title of alpha"
chk "low is pre-ticked"       "$(registry_checklist_rows | sed -n '3p')"       ON

# A medium item must not be pre-ticked. Rebuild with beta tunable to prove the
# default is read from the risk and not hardcoded per position.
mk 20 beta medium 1
registry_load
chk "medium is not pre-ticked" "$(registry_checklist_rows | sed -n '6p')"      OFF
chk "and still appears"        "$(registry_tunables | tr '\n' ' ')"            "alpha beta delta "

# --- 5. --only filters the registry -----------------------------------------
ONLY="alpha,delta"
registry_load
chk "only filters"            "$(registry_ids | tr '\n' ' ')"           "alpha delta "
chk "filtered-out id is gone" "$(registry_has beta && echo yes || echo no)"    no

# --- 6. an empty registry prints nothing ------------------------------------
# printf runs its format once even with no arguments, so the obvious one-liner
# emitted a blank line here. That blank id reached --list as an empty array
# subscript: two "REG_STATE: bad array subscript" errors and a row of padding.
ONLY="nosuchid"
registry_load
chk "empty registry has no ids" "$(registry_ids | wc -l)"                       0
chk "and no blank line"         "$(registry_ids | od -c | head -1 | wc -l)"     1
chk "tunables empty too"        "$(registry_tunables | wc -l)"                  0
chk "rows empty too"            "$(registry_checklist_rows | wc -l)"            0
ONLY=""

exit $fail
