# pi-tune

A TUI-driven optimization auditor for Raspberry Pi hosts. It fingerprints the
box, runs a registry of independent checks against it, and offers you a
checklist of the ones that apply. Nothing changes unless you ask.

Written for a mixed fleet: Armbian on a Pi 5, Debian 13 on Pi 3Bs. Every check
detects its own applicability rather than assuming a distro layout, so a module
that can't confirm what it's looking at reports `n/a` instead of guessing.

## Usage

```
sudo ./pi-tune.sh                          # audit only — the default
sudo ./pi-tune.sh --apply                  # audit, then pick changes from a checklist
sudo ./pi-tune.sh --apply --dry-run        # show the exact diffs, write nothing
sudo ./pi-tune.sh --apply --yes            # non-interactive, low-risk items only
sudo ./pi-tune.sh --rollbacks              # list rollback points
sudo ./pi-tune.sh --revert last            # undo the most recent run
./pi-tune.sh --fleet rpi5b,pi3a,pi3b       # SSH out and collect reports
```

`--report` and `--list` don't need root. `--apply` does, unless paired with
`--dry-run`.

## Safety model

- **Report-first.** The default mode reads and reports. Applying is opt-in twice
  over: the `--apply` flag, then ticking the box.
- **Risk-tiered defaults.** Only `low` items come pre-selected. `medium` and
  `high` start unticked and you have to reach for them.
- **Snapshot before write.** Every file is copied to
  `/var/backups/pi-tune/<timestamp>/files/<original path>` before it's touched.
  Files that didn't exist before are recorded in `created.list` so revert
  deletes them rather than leaving orphans.
- **Attempt-time recording.** A module is written to `applied.list` *before* it
  runs, so a module that dies halfway is still reachable by `--revert`.
- **Health gate.** Units that were active before the run are re-checked after.
  If one is down, you're offered an automatic rollback.
- **Diffs on demand.** `--dry-run` routes every file write through `diff -u`, so
  you see the precise change before committing to it.

## Check registry

| ID | Risk | Applies when |
|---|---|---|
| `journald-cap` | low | Journal has no `SystemMaxUse` set |
| `root-noatime` | medium | Root is ext/f2fs/btrfs on SD or USB without `noatime` |
| `docker-log-caps` | medium | Docker present, `max-size` unset in `daemon.json` |
| `zram-swap` | low | ≤2 GB RAM, no zram swap, Armbian's own zram not running |
| `usb-autosuspend` | medium | An SDR is attached and autosuspend is live |
| `cpu-governor` | medium | SDR/MLAT workload and governor isn't `performance` |
| `chrony-timesync` | low | MLAT workload with no disciplined NTP client |
| `dvb-blacklist` | low | RTL dongle present, `dvb_usb_rtl28xxu` not blacklisted |
| `wifi-powersave` | low | A wireless interface has power save on |
| `headless-target` | medium | No local session but default target is graphical |
| `idle-services` | low | ModemManager / triggerhappy / CUPS running unused |
| `pcie-gen3` | high | Pi 5 with NVMe still linked at Gen 2 |

Deliberately **not** included: disabling bluetooth (easy to regret), disabling
avahi (breaks `.local` resolution), `Storage=volatile` for the journal (loses
the logs you need when something breaks), and swapping the I/O scheduler
(kernel defaults are already sensible on both mq-deadline and none).

## Writing a check

Drop a file in `checks/`. The numeric prefix orders it; the ID is what the CLI
and rollback records use.

```bash
CHECK_ID="my-check"
CHECK_TITLE="One line, shown in the checklist"
CHECK_RISK="low"          # low | medium | high

check_detect() {          # 0 = already good, 1 = needs work, 2 = doesn't apply
    [[ $PI_GEN == 5 ]] || return 2
    grep -q something /etc/somefile && return 0
    return 1
}

check_why()    { echo "Why this matters, with live values where possible."; }

check_impact() { cat <<'EOF'
What applying it changes, what it costs, and what to watch afterwards.
Static prose — no live values. Shown before the boxes are ticked.
EOF
}

check_apply()  { write_drop_in /etc/foo.conf <<'EOF'
setting=value
EOF
}

check_revert()      { return 0; }   # before files are restored: stop things
check_revert_post() { return 0; }   # after files are restored: reload things
```

Return `2` liberally. A check that can't positively confirm the condition should
declare itself inapplicable rather than act on an assumption.

`check_why` and `check_impact` answer different questions and both are shown
before anything is applied — in the report, and on the review screen the TUI
puts ahead of the checklist. `check_why` is evidence that *this* host needs the
change, so it reads live values. `check_impact` is what applying it costs, so
it's static prose: the follow-up work it creates, what gets slower, hotter or
less accurate, and what to watch afterwards. Write the cost honestly — the
review screen is the last point at which someone can decline.

File restores are automatic, so the revert hooks only handle things that aren't
files — a service you enabled, a package you installed. Which of the two you
want depends on the side of the restore your work has to happen on:

- `check_revert` runs **before** files go back. Use it to *stop* something that
  still needs its config on disk — `systemctl disable --now` on a unit whose
  unit file is about to be deleted.
- `check_revert_post` runs **after** files are back. Use it to *reload*
  something so it notices the reverted config — restarting journald, remounting
  `/`, reloading NetworkManager. Doing this in `check_revert` re-reads the very
  config you are removing and silently keeps it.

Getting this backwards is the one mistake here that reports success and changes
nothing. Use the helpers in `lib/util.sh` (`install_file`, `write_drop_in`, `sysctl_drop_in`,
`config_txt_set`, `cmdline_add`, `pkg_install`, `run`) rather than raw
redirection: they carry the backup, dry-run, and rollback plumbing.

Available from `lib/probe.sh`: `PI_MODEL`, `PI_GEN`, `DISTRO_ID`,
`DISTRO_PRETTY`, `IS_ARMBIAN`, `RAM_MB`, `PAGE_SIZE`, `ARCH`, `CPU_COUNT`,
`FIRMWARE_DIR`, `CONFIG_TXT`, `CMDLINE_TXT`, `ARMBIAN_ENV`, `ROOT_SRC`,
`ROOT_FSTYPE`, `ROOT_DISK`, `ROOT_IS_SD`, `ROOT_IS_NVME`, `ROOT_IS_USB`,
`HAS_NVME`, `SDR_TYPE`, `HAS_SDR`, `HAS_DOCKER`, `HAS_NM`, `DOES_MLAT`,
`IS_HEADLESS`, `WIFI_IFACES`, `CRITICAL_UNITS`.

The list is the contract: a global with no consumer gets deleted rather than
kept on speculation, so add one when a check needs it, not before. Empty always
means "could not tell" — never a default.

## Notes for this fleet

The Pi 5 running the ADS-B stack is the host to be careful with. `cpu-governor`
and `usb-autosuspend` are the two worth having there, but the governor change
runs the SoC hotter — check thermals before leaving it. `pcie-gen3` is marked
high risk on purpose: it's outside the certified spec and a minority of drives
won't hold the link.

`root-noatime` and `zram-swap` are where the Pi 3Bs gain most. Neither will
trigger on the Pi 5 if it's booting from NVMe with 8 GB of RAM.

`vcgencmd` is intentionally never called — it's Raspberry Pi OS userland and
isn't reliably present on Armbian, so thermal and throttle state are read from
sysfs or skipped.
