set -uo pipefail
repo="$1"; cd "$repo" || exit 1

root=$(mktemp -d); trace="$root/trace"; conf="$root/etc/deep/nest/drop.conf"
export PI_TUNE_CHECK_DIR="$root/checks"; mkdir -p "$PI_TUNE_CHECK_DIR"

cat > "$PI_TUNE_CHECK_DIR/10-fake.sh" <<FAKE
CHECK_ID="fake"
CHECK_TITLE="ordering probe"
CHECK_RISK="low"
_f="$conf"
check_detect() { [[ -f \$_f ]] && return 0; return 1; }
check_why()    { echo probe; }
check_apply()  { write_drop_in "\$_f" <<'EOF'
applied=yes
EOF
}
check_revert()      { echo "revert:\$([[ -f \$_f ]] && echo present || echo gone)" >> "$trace"; }
check_revert_post() { echo "post:\$([[ -f \$_f ]] && echo present || echo gone)" >> "$trace"; }
FAKE

# The driver guards its entry point, so sourcing it defines do_revert and runs
# nothing - the function under test is the real one, not a copy.
BACKUP_ROOT="$root/backups"; DRY_RUN=0; VERBOSE=0; NO_TUI=1; ONLY=""
. ./pi-tune.sh
BACKUP_ROOT="$root/backups"          # driver re-defaults it on source
registry_load

fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# --- apply half: install_file must record the dirs it creates ----------------
BACKUP_DIR="$root/backups/20260101-000000"; mkdir -p "$BACKUP_DIR"
echo fake > "$BACKUP_DIR/applied.list"
load_check "$PI_TUNE_CHECK_DIR/10-fake.sh"
check_apply

chk "drop-in written"       "$([[ -f $conf ]] && echo yes || echo no)"                yes
chk "created.list recorded" "$(cat "$BACKUP_DIR/created.list" 2>/dev/null)"           "$conf"
echo "     created.dirs:"; sed 's/^/       /' "$BACKUP_DIR/created.dirs"
chk "deepest dir first"     "$(head -1 "$BACKUP_DIR/created.dirs")"                   "$root/etc/deep/nest"

# --- revert half: real do_revert ---------------------------------------------
do_revert 20260101-000000 >/dev/null 2>&1

chk "file removed"     "$([[ -e $conf ]] && echo present || echo gone)"               gone
chk "nest dir removed" "$([[ -d $root/etc/deep/nest ]] && echo present || echo gone)" gone
chk "deep dir removed" "$([[ -d $root/etc/deep ]] && echo present || echo gone)"      gone

echo "     hook trace:"; sed 's/^/       /' "$trace"
chk "check_revert ran BEFORE delete" "$(sed -n 1p "$trace")" "revert:present"
chk "check_revert_post ran AFTER"    "$(sed -n 2p "$trace")" "post:gone"

# --- rmdir must refuse a directory someone else populated --------------------
BACKUP_DIR="$root/backups/20260101-000001"; mkdir -p "$BACKUP_DIR"
echo fake > "$BACKUP_DIR/applied.list"
load_check "$PI_TUNE_CHECK_DIR/10-fake.sh"; check_apply
touch "$root/etc/deep/nest/somebody-elses.conf"
do_revert 20260101-000001 >/dev/null 2>&1

chk "occupied dir kept"      "$([[ -d $root/etc/deep/nest ]] && echo kept || echo removed)"              kept
chk "foreign file untouched" "$([[ -f $root/etc/deep/nest/somebody-elses.conf ]] && echo yes || echo no)" yes
chk "our file still removed" "$([[ -e $conf ]] && echo present || echo gone)"                            gone

rm -rf "$root"
exit $fail
