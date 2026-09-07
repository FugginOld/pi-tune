set -uo pipefail
cd "$1" || exit 1
. lib/util.sh
DRY_RUN=0
BACKUP_DIR=$(mktemp -d)

# Capture what revert would issue, instead of running systemctl.
run() { printf '%s\n' "$*" >> "$BACKUP_DIR/issued"; }

cat > "$BACKUP_DIR/idle-services.list" <<'LIST'
both.service enabled active
stopped.service enabled inactive
manual.service disabled active
neither.service disabled inactive
legacy.service
LIST

. checks/60-idle-services.sh
check_revert
echo "--- commands issued ---"; sed 's/^/    /' "$BACKUP_DIR/issued"

got() { grep -c "^systemctl $1 $2\$" "$BACKUP_DIR/issued"; }
# Anything that would START the unit: a literal start, or enable --now, which
# starts it without issuing one. Counting only "start" lets enable --now pass.
starts()  { grep -cE "^systemctl (start|enable --now) $1\$" "$BACKUP_DIR/issued"; }
# Anything that would ENABLE it: enable, or enable --now.
enables() { grep -cE "^systemctl enable( --now)? $1\$"      "$BACKUP_DIR/issued"; }
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# enabled+active -> re-enable and start
chk "both: enabled"        "$(enables both.service)"    1
chk "both: started"        "$(starts  both.service)"    1
# enabled+inactive -> re-enable but MUST NOT start   <- the fidelity bug
chk "stopped: enabled"     "$(enables stopped.service)" 1
chk "stopped: NOT started" "$(starts  stopped.service)" 0
# disabled+active -> start but MUST NOT enable
chk "manual: started"      "$(starts  manual.service)"  1
chk "manual: NOT enabled"  "$(enables manual.service)"  0
# disabled+inactive -> nothing at all
chk "neither: not enabled" "$(enables neither.service)" 0
chk "neither: not started" "$(starts  neither.service)" 0
# bare unit name from an older rollback point -> old behaviour
chk "legacy: enable --now" "$(grep -c '^systemctl enable --now legacy.service$' "$BACKUP_DIR/issued")" 1
# and enable --now must NOT be used for the new format
chk "no enable --now for new rows" "$(grep -c 'enable --now \(both\|stopped\|manual\|neither\)' "$BACKUP_DIR/issued")" 0

rm -rf "$BACKUP_DIR"
exit $fail
