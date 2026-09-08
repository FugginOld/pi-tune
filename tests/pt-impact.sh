set -uo pipefail
cd "$1" || exit 1

DRY_RUN=0; VERBOSE=0; NO_TUI=1; ONLY=""; ASSUME_YES=0
. ./pi-tune.sh
ui_init; probe_host

fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# 1. Every module must supply impact text. load_check installs a no-op default,
#    so a module that forgets check_impact yields the empty string here.
missing=""
for f in checks/*.sh; do
    load_check "$f" || { missing="$missing $f(load)"; continue; }
    [[ -n "$(check_impact 2>/dev/null)" ]] || missing="$missing $(basename "$f")"
done
chk "every module has impact text" "${missing:-none}" none
chk "module count" "$(ls checks/*.sh | wc -l)" 12

# 1b. The driver must define its functions when sourced and run nothing. Six
#     tests used to get this by sed-deleting `main "$@"` into a temp copy - a
#     test surface made of a regex on the file's last line. Measured in a
#     subshell, because this file has already sourced the driver above.
chk "sourcing runs nothing"  "$(bash -c '. ./pi-tune.sh 2>&1')"                     ""
chk "sourcing returns 0"     "$(bash -c '. ./pi-tune.sh >/dev/null 2>&1; echo $?')" 0
chk "sourcing defines apply" "$(bash -c '. ./pi-tune.sh >/dev/null 2>&1; declare -F apply_ids >/dev/null && echo yes || echo no')" yes
# The control: executing it still runs main. Without this the three above pass
# for a driver whose entry point was deleted rather than guarded.
chk "executing still runs"   "$(bash ./pi-tune.sh --list 2>/dev/null | wc -l)"      12

# 2. Wrapped output must fit whiptail's 78-column box.
over=0
for f in checks/*.sh; do
    load_check "$f"
    while IFS= read -r line; do
        [[ ${#line} -gt 72 ]] && { echo "     too wide (${#line}): $line"; over=$((over+1)); }
    done < <(_field 'Effect:' "$(check_impact)")
done
chk "no wrapped line over 72 cols" "$over" 0

# 3. review_text structure: one Why and one Effect per index, and continuation
#    lines aligned under the label at column 10.
scan_checks
p=(); for i in "${!C_ID[@]}"; do p+=("$i"); done          # all 12
out=$(review_text "${p[@]}")
chk "one Why per check"    "$(grep -c '^  Why:   ' <<<"$out")"    12
chk "one Effect per check" "$(grep -c '^  Effect:' <<<"$out")"    12
chk "header names host"    "$(grep -c "^12 change(s) apply to $(hostname)\.$" <<<"$out")" 1
chk "continuations at col 10" "$(grep -c '^          [^ ]' <<<"$out" | awk '$1>0{print "yes"; exit} {print "no"}')" yes
chk "no line over 72 cols" "$(awk 'length($0)>72' <<<"$out" | wc -l)" 0

# 4. A module with no check_impact must degrade to Why-only, not print an
#    empty Effect label.
C_IMPACT[0]=""
out=$(review_text 0)
chk "empty impact omits Effect" "$(grep -c '^  Effect:' <<<"$out")" 0
chk "empty impact keeps Why"    "$(grep -c '^  Why:   ' <<<"$out")" 1

exit $fail
