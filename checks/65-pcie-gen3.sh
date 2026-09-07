#!/usr/bin/env bash
# shellcheck disable=SC2034  # CHECK_* metadata is read by the pi-tune driver after sourcing
# Pi 5's PCIe slot is certified at Gen 2 but runs most NVMe drives at Gen 3.
# Roughly doubles throughput; a minority of drives are unstable at Gen 3.
CHECK_ID="pcie-gen3"
CHECK_TITLE="Raise Pi 5 PCIe link to Gen 3 (NVMe)"
CHECK_RISK="high"

check_detect() {
    [[ ${PI_GEN:-} == 5 ]] || return 2
    [[ $HAS_NVME -eq 1 ]] || return 2
    [[ -n ${CONFIG_TXT:-} ]] || return 2
    config_txt_has 'dtparam=pciex1_gen=3' && return 0
    return 1
}

check_why() {
    echo "NVMe on a Pi 5 running the PCIe link at Gen 2 — Gen 3 is unofficial but usually roughly doubles throughput."
}

check_impact() {
    cat <<'EOF'
Raises the Pi 5 PCIe link from Gen 2 to Gen 3, roughly doubling NVMe throughput. This is outside Raspberry Pi's certified spec: a minority of drives negotiate the link and then fail under sustained I/O. Needs a reboot, and needs a real read/write load to trust - a spot check will not surface it.
EOF
}

check_apply() {
    config_txt_set 'dtparam=pciex1_gen=3' || return 1
    require_manual "Unofficial speed. After reboot verify with \`dmesg | grep -i pcie\` and run a read/write test; if the drive drops out, revert this change."
}

check_revert() { return 0; }
