#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# Bound Docker's json-file logs. Default is unlimited, which quietly eats
# the disk on any container that logs steadily.
CHECK_ID="docker-log-caps"
CHECK_TITLE="Cap Docker container log size"
CHECK_RISK="medium"

_dconf="/etc/docker/daemon.json"
_cdir="/var/lib/docker/containers"

check_detect() {
    [[ $HAS_DOCKER -eq 1 ]] || return 2
    # No daemon.json at all: the driver default is unlimited, and check_apply
    # can write a fresh file without needing to merge anything.
    [[ -f $_dconf ]] || return 1
    # Merging into an existing daemon.json needs python3. Without it check_apply
    # can only fail, so report inapplicable rather than offer a fix that cannot
    # run. The python exit codes below are the check states directly.
    have python3 || return 2
    python3 - "$_dconf" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        text = fh.read().strip()
    cfg = json.loads(text) if text else {}
except (OSError, ValueError):
    sys.exit(2)   # unreadable or not valid JSON — we cannot say, so don't guess
if not isinstance(cfg, dict):
    sys.exit(2)
opts = cfg.get("log-opts")
sys.exit(0 if isinstance(opts, dict) and opts.get("max-size") else 1)
PY
}

check_why() {
    # numfmt --to=iec, matching journald-cap's "~17M". The old divisor printed
    # "%.0f MB", so every log under half a megabyte rendered as "largest today:
    # 0 MB" - a medium-risk change citing a measurement that argues against it.
    # "today" was wrong too: nothing here is scoped to a day. This is the
    # largest json.log currently on disk, which grows from container start or
    # the last rotation.
    local biggest=""
    biggest=$(find "$_cdir" -name '*-json.log' -printf '%s\n' 2>/dev/null \
              | sort -n | tail -n1 | numfmt --to=iec 2>/dev/null)
    echo "Container logs are unbounded${biggest:+ (largest on disk: $biggest)}."
}

check_impact() {
    cat <<'EOF'
Caps container logs at 10 MB x 3 files. Takes effect only after systemctl restart docker, which bounces every container unless live-restore is on. Existing containers keep their current settings until recreated, so this protects new ones rather than fixing logs already on disk.
EOF
}

check_apply() {
    local tmp; tmp=$(mktemp) || return 1

    if have python3; then
        python3 - "$_dconf" > "$tmp" <<'PY' || { rm -f "$tmp"; return 1; }
import json, os, sys
path = sys.argv[1]
cfg = {}
if os.path.exists(path):
    with open(path) as fh:
        text = fh.read().strip()
    if text:
        cfg = json.loads(text)
cfg.setdefault("log-driver", "json-file")
opts = cfg.setdefault("log-opts", {})
opts.setdefault("max-size", "10m")
opts.setdefault("max-file", "3")
print(json.dumps(cfg, indent=2))
PY
    elif [[ ! -f $_dconf ]]; then
        cat > "$tmp" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
    else
        rm -f "$tmp"
        err "daemon.json exists and python3 is unavailable to merge it safely"
        return 1
    fi

    install_file "$tmp" "$_dconf" 0644 || return 1
    require_manual "Restart Docker to pick up log caps (\`systemctl restart docker\`) — this restarts containers unless live-restore is on. Existing containers keep their old settings until recreated."
    return 0
}

check_revert() { require_manual "Restart Docker to drop the reverted log settings."; }
