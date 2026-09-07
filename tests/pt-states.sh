set -uo pipefail
cd "$1" || exit 1
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# "Already satisfied" and "pi-tune applied it" are different facts, and the
# report collapsed them into OK. root-noatime reads satisfied on a stock box
# pi-tune never touched; journald-cap reads satisfied because we capped it.
# Only the second is revertable, so only the second is DONE.
root=$(mktemp -d)
drv="$1/.pt-states-test.sh"; trap 'rm -f "$drv"; rm -rf "$root"' EXIT
sed '$ { /^main "\$@"$/d; }' pi-tune.sh > "$drv"

export PI_TUNE_BACKUP_ROOT="$root/backups"
NO_TUI=1
# shellcheck disable=SC1090
. "$drv"

# label <rc> <id> — rendered state word, trimmed. Colours are empty off a tty.
label() { local s; s=$(state_label "$1" "${2:-}"); echo "${s%"${s##*[![:space:]]}"}"; }

run_with() {                       # run_with <TS> <id>... — a fake rollback point
    local ts=$1; shift
    mkdir -p "$PI_TUNE_BACKUP_ROOT/$ts"
    printf '%s\n' "$@" > "$PI_TUNE_BACKUP_ROOT/$ts/applied.list"
}

# --- 1. no backups at all ---------------------------------------------------
# An unprivileged report on a box that has never applied anything. Must not
# crash and must not claim DONE for anything.
applied_index
chk "no backups: satisfied is OK" "$(label 0 journald-cap)" "OK"
chk "no backups: index empty"     "${#APPLIED[@]}"          0

# --- 2. the pair that exists on pi3b-DNS1 -----------------------------------
run_with 20260907-124902 journald-cap
applied_index
chk "applied+satisfied -> DONE"   "$(label 0 journald-cap)" "DONE"
chk "satisfied only    -> OK"     "$(label 0 root-noatime)" "OK"
chk "index records the run"       "${APPLIED[journald-cap]}" 20260907-124902

# --- 3. the other two states ignore the index -------------------------------
chk "pending -> TUNE"             "$(label 1 journald-cap)" "TUNE"
chk "pending -> TUNE (unapplied)" "$(label 1 root-noatime)" "TUNE"
chk "inapplicable -> N/A"         "$(label 2 pcie-gen3)"    "N/A"
chk "inapplicable ignores index"  "$(label 2 journald-cap)" "N/A"

# --- 4. a reverted tune is not DONE -----------------------------------------
# Phase 2 writes this marker per module. Without honouring it, a tune applied
# and then undone would read DONE forever and the revert page would offer to
# undo it twice.
mkdir -p "$PI_TUNE_BACKUP_ROOT/20260907-124902/modules/journald-cap"
touch "$PI_TUNE_BACKUP_ROOT/20260907-124902/modules/journald-cap/reverted"
applied_index
chk "reverted -> back to OK"      "$(label 0 journald-cap)" "OK"
chk "reverted leaves index empty" "${#APPLIED[@]}"          0

# --- 5. re-applied after a revert ------------------------------------------
run_with 20260908-090000 journald-cap
applied_index
chk "re-applied -> DONE again"    "$(label 0 journald-cap)" "DONE"
chk "newest run wins"             "${APPLIED[journald-cap]}" 20260908-090000

# --- 6. several tunes in one run --------------------------------------------
run_with 20260908-100000 wifi-powersave idle-services
applied_index
chk "multi-tune run: first"       "$(label 0 wifi-powersave)" "DONE"
chk "multi-tune run: second"      "$(label 0 idle-services)"  "DONE"
chk "untouched id still OK"       "$(label 0 zram-swap)"      "OK"

# --- 7. newest wins even when disk order disagrees with name order ----------
# Creates the NEWER-named run first, so creation order is the reverse of name
# order. Unsorted, the older run would overwrite the newer one in the index.
#
# CANNOT FAIL ON EVERY PLATFORM, and that is recorded rather than hidden:
# removing the `| sort` from applied_index does not break this on a filesystem
# whose readdir returns entries in name order, which is what Git Bash on NTFS
# does — find comes back sorted whether we ask or not. On ext4 (the Pi, and CI)
# readdir is hash order and the sort is load-bearing. So treat a pass here as
# agreement, not proof; the sort stays because of the target filesystem, not
# because this assertion defends it.
mkdir -p "$PI_TUNE_BACKUP_ROOT"
run_with 20260910-000000 zram-swap
run_with 20260909-000000 zram-swap
applied_index
chk "newest wins vs disk order"   "${APPLIED[zram-swap]}"    20260910-000000

# --- 8. an unreadable backup root degrades, it does not fail ----------------
# Report mode runs unprivileged. If /var/backups/pi-tune cannot be read, the
# honest answer is "we cannot say we applied it", not a crash or a false DONE.
# BACKUP_ROOT is read from the env var once at source time, so this has to move
# the variable the function actually reads.
BACKUP_ROOT="$root/nonexistent"
applied_index; rc=$?
chk "missing root: rc 0"          "$rc"                      0
chk "missing root: no DONE"       "$(label 0 journald-cap)"  "OK"

exit $fail
