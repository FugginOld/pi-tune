set -uo pipefail
cd "$1" || exit 1
. lib/util.sh; . lib/ui.sh
NO_TUI=1; ui_init                      # force the plain-text fallback

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

exit $fail
