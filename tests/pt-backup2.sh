set -uo pipefail
cd "$1" || exit 1
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo yes ;; *) echo no ;; esac; }
exists() { [ -e "$1" ] && echo yes || echo no; }

# Per-tune revert needs to know which module wrote which file. ARCHITECTURE.md
# leaned on the opposite - "restore is a blind walk, nothing needs to know which
# module wrote it" - so backups grow a per-module level and the walk moves one
# level down. This drives the real do_apply and do_revert against temp paths.
root=$(mktemp -d)
drv="$1/.pt-backup2-test.sh"; trap 'rm -f "$drv"; rm -rf "$root"' EXIT
sed '$ { /^main "\$@"$/d; }' pi-tune.sh > "$drv"

export PI_TUNE_BACKUP_ROOT="$root/backups"
export PI_TUNE_CHECK_DIR="$root/checks"
mkdir -p "$PI_TUNE_CHECK_DIR"

tgt="$root/etc"; mkdir -p "$tgt"
printf 'original-a\n' > "$tgt/a.conf"        # pre-existing -> files/ mirror
                                             # b.conf absent -> created.list

mkmod() {                                    # mkmod <n> <id> <dest>
    cat > "$PI_TUNE_CHECK_DIR/$1-$2.sh" <<EOF
CHECK_ID="$2"; CHECK_TITLE="module $2"; CHECK_RISK="low"
check_detect() { return 1; }
check_why() { echo "why-$2"; }
check_apply() { local t; t=\$(mktemp); printf 'tuned-$2\n' > "\$t"; install_file "\$t" "$3" 0644; }
EOF
}
mkmod 10 mod-a "$tgt/a.conf"
mkmod 20 mod-b "$tgt/b.conf"

# shellcheck disable=SC1090
. "$drv"
NO_TUI=1; ASSUME_YES=1; DRY_RUN=0; VERBOSE=0; ONLY=""
PI_MODEL="test"; DISTRO_PRETTY="test"; RAM_MB=1; CPU_COUNT=1
ROOT_SRC=/dev/x; ROOT_FSTYPE=ext4; ROOT_MEDIA=""
CRITICAL_UNITS=(); NEEDS_MANUAL=(); NEEDS_REBOOT=0
unit_active() { return 0; }
ui_init
scan_checks
do_apply >/dev/null 2>&1

ts=$(basename "$(find "$PI_TUNE_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n1)")
run="$PI_TUNE_BACKUP_ROOT/$ts"

# --- 1. the layout ----------------------------------------------------------
chk "run holds applied.list"  "$(exists "$run/applied.list")"              yes
chk "manifest says schema=2"  "$(has x "$(cat "$run/manifest")" 'schema=2')" yes
chk "mod-a has its own subtree" "$(exists "$run/modules/mod-a")"           yes
chk "mod-b has its own subtree" "$(exists "$run/modules/mod-b")"           yes
chk "overwritten file mirrored" "$(exists "$run/modules/mod-a/files$tgt/a.conf")" yes
chk "mirror holds the original" "$(cat "$run/modules/mod-a/files$tgt/a.conf" 2>/dev/null)" original-a
chk "created file recorded"   "$(has x "$(cat "$run/modules/mod-b/created.list" 2>/dev/null)" "$tgt/b.conf")" yes
# The old single-tree layout must be gone, not merely shadowed.
chk "no run-level files/"     "$(exists "$run/files")"                     no
chk "post hash recorded"      "$(exists "$run/modules/mod-a/post.sha256")" yes

# Both modules actually ran.
chk "a.conf tuned"            "$(cat "$tgt/a.conf")"                       tuned-mod-a
chk "b.conf created"          "$(cat "$tgt/b.conf")"                       tuned-mod-b

# --- 2. revert ONE tune, leave the other alone ------------------------------
do_revert "$ts" mod-a >/dev/null 2>&1
chk "a.conf restored"         "$(cat "$tgt/a.conf")"                       original-a
chk "b.conf untouched"        "$(cat "$tgt/b.conf")"                       tuned-mod-b
chk "mod-a marked reverted"   "$(exists "$run/modules/mod-a/reverted")"    yes
chk "mod-b NOT marked"        "$(exists "$run/modules/mod-b/reverted")"    no

# The index Phase 1 built has to follow: mod-a stops being DONE, mod-b stays.
BACKUP_ROOT="$PI_TUNE_BACKUP_ROOT"; applied_index
chk "reverted tune drops out" "${APPLIED[mod-a]:-none}"                    none
chk "other tune still DONE"   "${APPLIED[mod-b]:-none}"                    "$ts"

# --- 3. reverting the rest still works --------------------------------------
do_revert "$ts" mod-b >/dev/null 2>&1
chk "created file deleted"    "$(exists "$tgt/b.conf")"                    no
chk "mod-b now marked"        "$(exists "$run/modules/mod-b/reverted")"    yes

# --- 4. the guard: something else changed the file after we applied ---------
# Per-tune revert is what makes this reachable. Restoring blindly would undo a
# later change that pi-tune did not make. Skip and say so; never clobber.
printf 'original-c\n' > "$tgt/c.conf"
m="$run/modules/mod-c"; mkdir -p "$m/files$tgt"
printf 'original-c\n' > "$m/files$tgt/c.conf"
printf 'tuned-c\n'    > "$tgt/c.conf"
( cd / && sha256sum "$tgt/c.conf" ) > "$m/post.sha256"
printf 'mod-c\n' >> "$run/applied.list"
printf 'changed-by-someone-else\n' > "$tgt/c.conf"      # drifted since apply

out=$(do_revert "$ts" mod-c 2>&1)
chk "drifted file not clobbered" "$(cat "$tgt/c.conf")" changed-by-someone-else
chk "and the operator is told"   "$(has x "$out" 'changed since')"          yes
# A skipped file must not silently pass as a clean revert.
chk "still marked reverted"      "$(exists "$m/reverted")"                  yes

# The same guard on the delete path, which is the worse half: this file did not
# exist before pi-tune made it, so revert wants to remove it — but someone has
# edited it since, and deleting it destroys their work rather than ours.
printf 'ours\n' > "$tgt/d.conf"
m2="$run/modules/mod-d"; mkdir -p "$m2"
printf '%s\n' "$tgt/d.conf" > "$m2/created.list"
( cd / && sha256sum "$tgt/d.conf" ) > "$m2/post.sha256"
printf 'theirs\n' > "$tgt/d.conf"
printf 'mod-d\n' >> "$run/applied.list"

out=$(do_revert "$ts" mod-d 2>&1)
chk "drifted created file kept"  "$(cat "$tgt/d.conf" 2>/dev/null)"         theirs
chk "delete path warns too"      "$(has x "$out" 'changed since')"          yes

# --- 5. a whole-run revert undoes in reverse apply order --------------------
# The two modules above are independent, so reverting them one at a time cannot
# show the order. Hand-build a run whose modules record when their hook fires:
# applied in x,y order, they must be undone y,x. Getting this backwards means a
# module's post hook - a reload - runs over config another module has not put
# back yet, which is the whole reason revert has two hooks.
log="$root/hook.log"; : > "$log"
for n in x y; do
    cat > "$PI_TUNE_CHECK_DIR/3${n}-mod-$n.sh" <<EOF
CHECK_ID="mod-$n"; CHECK_TITLE="module $n"; CHECK_RISK="low"
check_detect() { return 0; }
check_revert() { echo "mod-$n" >> "$log"; }
EOF
done
C_ID=(); C_TITLE=(); C_RISK=(); C_FILE=(); C_WHY=(); C_IMPACT=(); C_STATE=()
scan_checks

ord="$PI_TUNE_BACKUP_ROOT/20260202-000000"
mkdir -p "$ord/modules/mod-x" "$ord/modules/mod-y"
printf 'host=t\nmodel=t\nversion=1.0.0\nschema=2\n' > "$ord/manifest"
printf 'mod-x\nmod-y\n' > "$ord/applied.list"
do_revert 20260202-000000 >/dev/null 2>&1
chk "undone in reverse order"  "$(tr '\n' ' ' < "$log")"                    "mod-y mod-x "

# --- 6. schema 1 rollback points still revert whole -------------------------
# pi3b-DNS1 holds three of these and one is live. A missing schema= in the
# manifest means the old single-tree layout and the old whole-run walk.
old="$PI_TUNE_BACKUP_ROOT/20260101-000000"
mkdir -p "$old/files$tgt"
printf 'host=t\nmodel=t\nversion=1.0.0\n' > "$old/manifest"   # no schema= line
printf 'original-a\n' > "$old/files$tgt/a.conf"
printf 'mod-a\n' > "$old/applied.list"
printf 'v1-modified\n' > "$tgt/a.conf"

do_revert 20260101-000000 >/dev/null 2>&1
chk "v1 restores whole run"   "$(cat "$tgt/a.conf")"                       original-a

exit $fail
