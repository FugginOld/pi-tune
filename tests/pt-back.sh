set -uo pipefail
cd "$1" || exit 1
root=$(mktemp -d)

# Drive do_apply over the plain-text fallback with a scripted keystroke stream.
# Sequence: tick 1 and 2 -> answer No (Back) -> checklist must reopen with BOTH
# still ticked -> press Enter to take those defaults -> answer y.
trap 'rm -rf "$root"' EXIT

export PI_TUNE_CHECK_DIR="$root/checks"; mkdir -p "$PI_TUNE_CHECK_DIR"
for n in 1 2 3; do
  cat > "$PI_TUNE_CHECK_DIR/1$n-c$n.sh" <<EOF
CHECK_ID="c$n"
CHECK_TITLE="check $n"
CHECK_RISK="low"
check_detect() { return 1; }
check_why() { echo why; }
check_apply() { echo "APPLIED c$n" >> "$root/applied"; }
EOF
done

BACKUP_ROOT="$root/backups"; DRY_RUN=0; VERBOSE=0; NO_TUI=1; ONLY=""; ASSUME_YES=0
. ./pi-tune.sh
BACKUP_ROOT="$root/backups"; PI_MODEL="test"; DISTRO_PRETTY="test"; RAM_MB=1; CPU_COUNT=1
ROOT_SRC=/dev/x; ROOT_FSTYPE=ext4; CRITICAL_UNITS=(); NEEDS_MANUAL=(); NEEDS_REBOOT=0
unit_active() { return 0; }
scan_checks

# 1,2  -> select c1 and c2
# n    -> Back
# ""   -> accept defaults (which must now be c1+c2)
# y    -> Apply
out=$(printf '1,2\nn\n\ny\n' | do_apply 2>&1)
echo "$out" | sed 's/^/    /'

fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

chk "checklist shown twice"      "$(grep -c 'Select numbers' <<<"$out")" 2
chk "ticks carried back: c1"     "$(grep -c '^ *1) \[x\] \[low\] check 1' <<<"$out")" 2
chk "ticks carried back: c2"     "$(grep -c '^ *2) \[x\] \[low\] check 2' <<<"$out")" 2
# c3 is low-risk so it pre-ticks on pass 1; on pass 2 the defaults must narrow
# to what was actually selected, so it comes back unticked. One of each.
chk "c3 ticked on pass 1"        "$(grep -c '^ *3) \[x\] \[low\] check 3' <<<"$out")" 1
chk "c3 unticked on pass 2"      "$(grep -c '^ *3) \[ \] \[low\] check 3' <<<"$out")" 1
chk "applied c1"                 "$(grep -c '^APPLIED c1$' "$root/applied")" 1
chk "applied c2"                 "$(grep -c '^APPLIED c2$' "$root/applied")" 1
chk "did not apply c3"           "$(grep -c '^APPLIED c3$' "$root/applied" || true)" 0
chk "applied exactly twice"      "$(wc -l < "$root/applied")" 2

exit $fail
