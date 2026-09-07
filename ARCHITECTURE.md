# Architecture

## Layout

```text
pi-tune.sh                 driver: argument parsing, registry, report, apply, revert
lib/util.sh                logging, run/dry-run, backup + install helpers, systemd/apt/firmware primitives
lib/probe.sh               one-shot host fingerprint; exports the globals every check reads
lib/ui.sh                  whiptail/dialog wrapper with a plain-text fallback for every entry point
checks/NN-<id>.sh          one tuning per file; numeric prefix orders, CHECK_ID identifies
.github/workflows/shellcheck.yml
```

`pi-tune.sh` resolves `lib/` relative to its own path and `checks/` from
`PI_TUNE_CHECK_DIR` or `$SCRIPT_DIR/checks`. The tree above is load-bearing:
the driver sources `$LIB_DIR/util.sh` before it can report an error, so a
misplaced lib fails with a bare bash message rather than a diagnostic.

## Why a registry of sourced modules

The driver knows nothing about any specific tuning. A check file declares three
variables and up to four functions; the driver sources it into its own shell.
No subprocess, so a module gets the probe globals and the backup plumbing for
free and can leave state behind (`require_reboot`, `require_manual`) that the
driver reads afterward.

Isolation is by reset, not by subshell. `load_check()` unsets the four hook
functions, reinstalls safe defaults, clears `CHECK_ID`/`CHECK_TITLE` and sets
`CHECK_RISK=medium`, then sources. A module that omits `check_revert` gets the
no-op — never the previous module's. The price of sharing one shell is that a
module can clobber a driver global. Module-private state is prefixed with `_`
(`_jconf`, `_gov`, `_unit`, `_candidates`) and modules never assign to a `C_*`,
`PI_*`, `HAS_*`, `ROOT_*` or `NEEDS_*` name.

## The three-state detect contract

`check_detect` returns a state, not a boolean:

| rc | Meaning | Report | Offered in checklist |
|----|---------|--------|----------------------|
| 0 | Condition already satisfied | `OK` | no |
| 1 | Applies here and is not satisfied | `TUNE` | yes |
| 2 | Does not apply to this host | `n/a` (hidden unless `-v`) | no |

The default installed by `load_check` is `2`. A module that cannot positively
confirm the condition must return `2` rather than guess — the whole point of
the split is that "I could not tell" and "it is fine" are different answers,
and only one of them is safe to act on. `root-noatime` returning `2` when
`/etc/fstab` has no root entry is the pattern.

## Lifecycle

**Report** (`--report`, default, no root):
`ui_init` -> `probe_host` -> `scan_checks` (source each module, run
`check_detect` and `check_why`, record state) -> `print_report`.

**Apply** (`--apply`, root, or `--dry-run` without):
report, then `do_apply`:

1. Collect state-1 checks; `low` risk pre-ticked, `medium`/`high` unticked.
2. `ui_checklist` -> selection, then a second `ui_yesno` confirmation.
3. `new_backup_dir` — `/var/backups/pi-tune/<YYYYmmdd-HHMMSS>/` plus `manifest`.
4. `health_snapshot` — copies `CRITICAL_UNITS` (units already active at probe
   time) into `ACTIVE_BEFORE`.
5. Per selected id: append to `applied.list` **before** calling `check_apply`,
   re-source the module, run it. A module that dies mid-write is already
   recorded and stays reachable by `--revert`.
6. `health_verify` — any unit in `ACTIVE_BEFORE` no longer active triggers an
   offer to roll the whole run back.
7. Print `NEEDS_MANUAL` items and the reboot flag.

**Revert** (`--revert TS|last`, root):
`scan_checks` runs first — revert needs the registry to map an id back to a
file. Then, in order:

1. `check_revert` for each id in `applied.list` — services, packages, and other
   non-file state, undone while the files are still in their applied form.
2. Restore every file under `<ts>/files/` to its mirrored absolute path.
3. Delete every path in `created.list` — files that did not exist before.
4. `systemctl daemon-reload`, and `sysctl --system` if any sysctl drop-in was
   part of the run.

Hooks run before file restores because a hook such as
`systemctl disable --now zramswap.service` needs the config it was started with
still on disk.

## Probe

`probe_host` runs exactly once, before any module is sourced. Every check reads
these globals rather than re-detecting, so detection cost is paid once and two
checks can never disagree about the host.

Anything undetectable is left empty, and empty means unknown. Modules treat
empty as a reason to return `2`, never as a default.

| Global | Consumed by |
|---|---|
| `PI_MODEL`, `PI_GEN` | `pcie-gen3`, report header |
| `DISTRO_ID`, `DISTRO_PRETTY`, `IS_ARMBIAN` | report header |
| `RAM_MB` | `zram-swap`, `headless-target` |
| `ARCH`, `CPU_COUNT`, `PAGE_SIZE` | report header |
| `CONFIG_TXT`, `CMDLINE_TXT` | `usb-autosuspend`, `pcie-gen3`, `cmdline_add`, `config_txt_set` |
| `ROOT_SRC`, `ROOT_FSTYPE`, `ROOT_IS_SD`, `ROOT_IS_USB` | `root-noatime` |
| `HAS_NVME` | `pcie-gen3` |
| `SDR_TYPE`, `HAS_SDR` | `usb-autosuspend`, `cpu-governor`, `dvb-blacklist` |
| `HAS_DOCKER` | `docker-log-caps` |
| `HAS_NM` | `wifi-powersave` |
| `DOES_MLAT` | `cpu-governor`, `chrony-timesync` |
| `IS_HEADLESS` | `headless-target` |
| `WIFI_IFACES` | `wifi-powersave` |
| `CRITICAL_UNITS` | health gate |

A probe global with no consumer gets deleted, not kept on speculation — the
README publishes this list as the check-authoring contract, and a documented
global that no longer matches the code is worse than a shorter list. Two are
retained without a consumer because each encodes a fact that would have to be
rediscovered rather than retyped: `ARMBIAN_ENV` (Armbian can override
`config.txt` from its own env file, so a boot-config check must read both) and
`ROOT_DISK` (the partition-suffix stripping differs by bus — `mmcblk0p2` and
`nvme0n1p1` drop `p<N>`, `sda1` drops a bare `<N>`). Both carry that reasoning
as a comment in `lib/probe.sh`.

`vcgencmd` is deliberately never called. It is Raspberry Pi OS userland and is
not reliably present on Armbian, so thermal and throttle state come from sysfs
or are skipped.

`DOES_MLAT` is inferred two ways: known unit names, and — when Docker is
present — container image names matching `adsb|piaware|readsb|airnav`. It gates
the two changes that trade heat and power for timing stability.

## Backup model

```text
/var/backups/pi-tune/20260906-141233/
├── manifest              host, model, pi-tune version
├── applied.list          check ids, written before each attempt
├── created.list          absolute paths that did not exist before the run
├── idle-services.list    module-private: units the idle-services check disabled
└── files/                mirror of the original tree
    └── etc/fstab
```

`files/` mirrors absolute paths, so restore is a blind walk: for every file
under `files/`, strip the prefix and `cp -a` it back. Nothing needs to know
which module wrote it.

Every write funnels through `install_file()`, which does the same three things
in the same order every time: `record_absent` (so a new file can be deleted on
revert), `backup_file` (and **refuses to write** if the backup fails), then
replace. `write_drop_in`, `sysctl_drop_in`, `config_txt_set` and `cmdline_add`
are all thin wrappers over it — a module that writes with plain redirection
loses backup, dry-run and rollback in one go.

`install_file` writes with `cat "$src" > "$dest"` rather than `mv`, preserving
the destination's existing owner and mode. This is what lets it write into the
vfat firmware partition without fighting the mount options.

## Dry run

`--dry-run` is not a separate code path. `run()` prints instead of executing,
`backup_file` prints instead of copying, and `install_file` emits `diff -u`
against the current file (or the full body, marked `(new file)`, when the file
is new). The preview is produced by the same code that would do the write, so
it cannot drift from it.

## Safety invariants

1. **Report mode never needs root and never writes.** CI asserts this.
2. **Nothing is written without a backup.** `install_file` aborts the write if
   `backup_file` fails.
3. **`applied.list` is written before the attempt, not after.** A module that
   fails halfway has still touched the system.
4. **Only `low` risk is pre-selected**, and `--yes` applies *only* low-risk
   items. There is no flag that applies a `high` item unattended.
5. **A unit running before the run must be running after it**, or the operator
   is offered a rollback.
6. **Detect is read-only.** `check_detect` and `check_why` run on every check on
   every invocation, including plain `--report` as an unprivileged user.

## Accepted limitations

- **Packages are never removed.** Revert undoes service state but leaves the
  package installed; the checks that install one (`zram-swap`,
  `chrony-timesync`) raise a `require_manual` note instead. Auto-purging a
  package another service has come to depend on is worse than leaving it.
- **`pkg_install` refreshes package lists only after a failed install.** A box
  that has been off for a while 404s on stale lists; an unconditional
  `apt-get update` would cost every apply a network round trip, including the
  ones that install nothing.
- **Reboot-gated changes are not verified.** `cmdline_add` and `config_txt_set`
  set `NEEDS_REBOOT`; the health gate cannot see whether the change is good
  until the next boot, by which time pi-tune is long gone.
- **The health gate only covers units active at probe time.** A unit that was
  already down stays down and is not reported.
- **No lock.** Two concurrent `--apply` runs on one host will interleave their
  backup directories. Single-operator tool; not worth the flock.
- **`--fleet` is report-only** by construction: it ships the tree over SSH and
  runs `--report --no-tui`. There is no remote apply.
