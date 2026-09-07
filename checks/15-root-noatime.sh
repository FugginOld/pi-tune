#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# noatime on the root filesystem. On SD and cheap USB media the atime writes
# are pure wear for almost no benefit.
CHECK_ID="root-noatime"
CHECK_TITLE="Mount root with noatime"
CHECK_RISK="medium"

check_detect() {
    [[ -r /etc/fstab ]] || return 2
    case "$ROOT_FSTYPE" in ext2|ext3|ext4|f2fs|btrfs|xfs) ;; *) return 2 ;; esac
    # Only worth it on flash-backed roots.
    [[ $ROOT_IS_SD -eq 1 || $ROOT_IS_USB -eq 1 ]] || return 2
    awk '!/^[[:space:]]*#/ && NF>=4 && $2=="/" {found=1; if ($4 ~ /(^|,)noatime(,|$)/) ok=1}
         END {exit (found ? (ok ? 0 : 1) : 2)}' /etc/fstab
}

check_why() {
    echo "Root is on flash with atime updates enabled — every read writes metadata."
}

check_apply() {
    local tmp; tmp=$(mktemp) || return 1
    awk 'BEGIN{OFS="\t"}
         /^[[:space:]]*#/ {print; next}
         NF>=4 && $2=="/" && $4 !~ /(^|,)noatime(,|$)/ {
             o=$4
             gsub(/(^|,)relatime/, ",", o)
             gsub(/(^|,)strictatime/, ",", o)
             gsub(/(^|,)atime/, ",", o)
             gsub(/,+/, ",", o)
             sub(/^,/, "", o); sub(/,$/, "", o)
             if (o == "") o = "defaults"
             $4 = o ",noatime"
             print; next
         }
         {print}' /etc/fstab > "$tmp" || return 1

    # Refuse to install a mangled fstab.
    awk '!/^[[:space:]]*#/ && NF>=4 && $2=="/"' "$tmp" | grep -q . || { err "rewrite lost the root entry"; rm -f "$tmp"; return 1; }

    install_file "$tmp" /etc/fstab 0644 || return 1
    run mount -o remount /
    return 0
}

check_revert() { run mount -o remount /; }
