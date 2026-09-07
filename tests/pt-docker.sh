set -uo pipefail
cd "$1" || exit 1
. lib/util.sh
fail=0
chk() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi; }

# docker-log-caps' check_why reported "largest today: 0 MB" on pi3b-DNS1: a
# medium-risk change quoting a measurement that undercuts it. The number was
# real, the formatting was not - "%.0f MB" floors every sub-megabyte log to 0.
root=$(mktemp -d); trap 'rm -rf "$root"' EXIT
HAS_DOCKER=1

# A log of $1 bytes, then whatever check_why says about it.
why_for() {
    rm -rf "$root/containers"; mkdir -p "$root/containers/abc123"
    [[ $1 -ge 0 ]] && head -c "$1" /dev/zero > "$root/containers/abc123/abc123-json.log"
    unset -f check_why; . checks/20-docker-log-caps.sh
    _cdir="$root/containers"
    check_why
}

# --- the reported size ------------------------------------------------------
chk "300 KB is not 0"      "$(why_for 307200)" \
    "Container logs are unbounded (largest on disk: 300K)."
chk "17 MB reads as 17M"   "$(why_for 17825792)" \
    "Container logs are unbounded (largest on disk: 17M)."
chk "1 KB stays visible"   "$(why_for 1024)" \
    "Container logs are unbounded (largest on disk: 1.0K)."

# The exact case seen on the box: small but non-zero must not floor to 0.
out=$(why_for 400000)
chk "sub-MB is not '0 MB'" "$(case $out in *"0 MB"*) echo yes ;; *) echo no ;; esac)" no
chk "sub-MB names a unit"  "$(case $out in *391K*) echo yes ;; *) echo no ;; esac)" yes

# --- no logs at all ---------------------------------------------------------
# find prints nothing, numfmt prints nothing, and the ${biggest:+} guard has to
# drop the whole parenthetical rather than emit an empty one.
rm -rf "$root/containers"; mkdir -p "$root/containers"
unset -f check_why; . checks/20-docker-log-caps.sh
_cdir="$root/containers"
chk "no logs -> no parenthetical" "$(check_why)" "Container logs are unbounded."

# A missing directory (unprivileged report mode cannot read it) must read the
# same way, not leak a find error into the sentence.
unset -f check_why; . checks/20-docker-log-caps.sh
_cdir="$root/does-not-exist"
chk "unreadable -> no parenthetical" "$(check_why 2>/dev/null)" \
    "Container logs are unbounded."

# --- detect still gates on docker -------------------------------------------
HAS_DOCKER=0
unset -f check_detect; . checks/20-docker-log-caps.sh
check_detect; chk "no docker -> n/a" "$?" 2

exit $fail
