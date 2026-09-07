#!/usr/bin/env bash
# Runs every pt-*.sh in this directory against the repo root.
#
# Each test is a standalone bash script taking the repo root as $1. It sources
# the real lib/*.sh and checks/*.sh rather than reimplementing them, prints one
# "ok <name>" or "FAIL <name>: ..." line per assertion, and exits nonzero if any
# assertion failed. There is no framework and no fixture directory on purpose:
# the tests are the assertions plus the code under test.
#
# Output is quiet on success - a passing test's rendered screens are noise. A
# failing test's full output is printed, because that is the only run where it
# is evidence.
set -uo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fail=0
total=0

for t in "$root"/tests/pt-*.sh; do
    name=$(basename "$t" .sh)
    out=$(bash "$t" "$root" 2>&1)
    rc=$?
    n=$(grep -c '^ok' <<<"$out")
    total=$((total + n))
    if [ "$rc" -eq 0 ]; then
        printf 'ok   %-12s %2d assertions\n' "$name" "$n"
    else
        printf 'FAIL %-12s %2d passed before failing\n' "$name" "$n"
        printf '%s\n' "$out" | sed 's/^/       /'
        fail=1
    fi
done

if [ "$fail" -eq 0 ]; then
    echo "--- $total assertions, all passing"
else
    echo "--- FAILED"
fi
exit $fail
