# HOWTO

Operator guide. For internals and the module contract, see
[ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- bash 4.4+ (`mapfile`, `${arr[@]}` under `set -u`), systemd, coreutils.
- `whiptail` (Debian: `libnewt`) or `dialog` for the checklist. Without either,
  every prompt degrades to a numbered plain-text list — nothing is lost but the
  boxes.
- Root for `--apply` and `--revert`. Not for `--report`, `--list`,
  `--rollbacks`, `--dry-run` or `--fleet`.

## Install on a box

```sh
git clone https://github.com/Fuggin/pi-tune.git /opt/pi-tune
chmod +x /opt/pi-tune/pi-tune.sh
```

The layout matters — `pi-tune.sh` looks for `lib/` and `checks/` beside itself:

```
pi-tune.sh
lib/{util,probe,ui}.sh
checks/*.sh
```

Verify before trusting it:

```sh
cd /opt/pi-tune && ./pi-tune.sh --list
```

That must print twelve check ids. If it prints
`check directory not found` or a bash "No such file" from a `.` line, the tree
is flat and the files need moving into `lib/` and `checks/`.

## First run

```sh
./pi-tune.sh
```

Reads only, and needs no root. On a terminal you get a menu; over a pipe, in CI
or under `--fleet` you get the same findings as plain text. Nothing about which
one you get is a flag — it is whether there is a terminal and a whiptail to
draw on.

The menu opens on the host it found, and offers `Tune`, `Quit`, and `Revert`
when there is something left to undo. `Tune` leads to a table of every check
and where this host stands, then to the selection, then to a confirm offering
`Apply`, `Dry run` and `Back`. Browsing all of that needs no root; without it
the `Apply` row is simply absent and the confirm says so, rather than the tool
refusing to start.

To skip the menu and get the text — what CI and `--fleet` run:

```sh
./pi-tune.sh --report --no-tui
```

Either way the findings read the same:

```
  [DONE] journald-cap               Cap systemd journal size
  [OK  ] root-noatime               Mount root with noatime
  [TUNE] wifi-powersave             Disable WiFi power save
        WiFi power save is on for wlan0 — expect periodic latency spikes.
```

| Marker | Meaning |
|---|---|
| `TUNE` | Applies to this host and is not set. Offered on `--apply`. |
| `DONE` | pi-tune applied it. Revertable. |
| `OK` | Already in the state pi-tune wants, but pi-tune did not put it there. |
| `N/A` | Does not apply here. Hidden unless you pass `-v`. |

Add `-v` to see the `N/A` rows and why each was skipped — that is the fastest
way to confirm the probe read the host correctly.

`DONE` and `OK` are the same `check_detect` result: the condition is satisfied.
They differ in who satisfied it, which is read from the `applied.list` of every
rollback point. It matters because only `DONE` can be reverted — `root-noatime`
reads `OK` on a stock Raspberry Pi OS image that already mounts with `noatime`,
and there is nothing there to undo.

## See the exact changes before making any

```sh
sudo ./pi-tune.sh --apply --dry-run
```

Tick items, and instead of writing, pi-tune prints a `diff -u` for every file
it would change and a `would run:` line for every command. Nothing is written
and no backup directory is created. This is the same code path that does the
real write, so the diff cannot be stale.

`--dry-run` does not require root, but running it unprivileged means some
detections (Docker log sizes, `/boot/firmware` reads) come back empty and the
preview will be thinner than the real thing. Use `sudo`.

## Apply

```sh
sudo ./pi-tune.sh --apply
```

1. Report prints.
2. Checklist. `low` items are pre-ticked; `medium` and `high` are not, and you
   have to reach for them deliberately.
3. Confirmation box listing exactly what is about to happen.
4. Each change runs, backing up every file it touches first.
5. Health gate: any service that was running before the run and is not running
   now offers you an immediate rollback.
6. Manual follow-ups and the reboot flag are printed last. Read them — several
   checks are only half-done without the follow-up (`docker-log-caps` needs a
   Docker restart; `cpu-governor` wants a day of thermal watching).

Non-interactive, low-risk only:

```sh
sudo ./pi-tune.sh --apply --yes
```

`--yes` applies **only** `low` risk items. There is no flag that will apply a
`high` item unattended.

One change at a time — the right way to do this on a box you care about:

```sh
sudo ./pi-tune.sh --apply --only wifi-powersave
```

## Roll back

```sh
sudo ./pi-tune.sh --rollbacks        # list points, newest last
sudo ./pi-tune.sh --revert last      # undo the most recent run
sudo ./pi-tune.sh --revert 20260906-141233
```

Undo one tune out of a run rather than the whole thing:

```sh
sudo ./pi-tune.sh --revert 20260907-144725 --only docker-log-caps
```

Revert undoes service and package-state changes first, then restores every
snapshotted file, then deletes files the run created. If the original run
required a reboot, so does the revert.

`--rollbacks` marks tunes already undone, so a point that still has something
left in it is obvious:

```
  20260907-144725      journald-cap(reverted) wifi-powersave
  20260906-141233      root-noatime [whole-run only]
```

`[whole-run only]` means a backup taken before per-module snapshots existed. It
still reverts, but only in one piece — nothing in it recorded which tune wrote
which file, so `--only` is refused rather than quietly undoing everything.

**A file that changed after pi-tune touched it is left alone.** Revert compares
each file against what the tune left behind; if it no longer matches, something
else has edited it since and the file is skipped with a warning instead of being
overwritten or deleted. You get a partial revert and a message saying which
files, which is better than silently destroying an edit that was not ours. Read
the warnings — the rest of the revert still ran.

Backups live in `/var/backups/pi-tune/`, override with `PI_TUNE_BACKUP_ROOT`.
They are never pruned; delete old timestamps by hand.

## Fleet

```sh
./pi-tune.sh --fleet rpi5b,pi3a,pi3b
```

Tars the tree, pipes it over SSH to each host, runs `--report --no-tui` there,
prints the result, and deletes the copy. Report only, by design — there is no
remote apply. Needs key-based SSH (`BatchMode=yes`, no password prompts).

## Verifying on the box

Each change and the single command that proves it landed. Run these yourself
after the reboot, not from pi-tune.

| Check | Verify with | Expect |
|---|---|---|
| `journald-cap` | `systemd-analyze cat-config systemd/journald.conf \| grep -i systemmaxuse` | `SystemMaxUse=200M` |
| `root-noatime` | `findmnt -no OPTIONS /` | contains `noatime` |
| `docker-log-caps` | `docker info --format '{{.LoggingDriver}}'` then `docker inspect -f '{{.HostConfig.LogConfig}}' <new container>` | `max-size:10m`. Existing containers keep old settings until recreated. |
| `zram-swap` | `zramctl` and `swapon --show` | a `/dev/zram0` device at ~50% of RAM, `zstd` |
| `usb-autosuspend` | `cat /sys/module/usbcore/parameters/autosuspend` | `-1` (after reboot) |
| `cpu-governor` | `cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` | `performance` on every core |
| `chrony-timesync` | `chronyc tracking` | `Leap status: Normal`, RMS offset under a millisecond after ~15 min |
| `dvb-blacklist` | `lsmod \| grep dvb` then `rtl_test -t` | no dvb modules; `rtl_test` finds the device |
| `wifi-powersave` | `iw dev wlan0 get power_save` | `Power save: off` |
| `headless-target` | `systemctl get-default` | `multi-user.target` |
| `idle-services` | `systemctl is-enabled ModemManager triggerhappy` | `disabled` / `masked` |
| `pcie-gen3` | `dmesg \| grep -i 'pcie.*link'` and `lspci -vv \| grep LnkSta` | link speed `8GT/s`. If the drive drops out under load, revert. |

Two that deserve a second pass a day later rather than a minute later:

- `cpu-governor` — `cat /sys/class/thermal/thermal_zone0/temp` (millidegrees).
  A Pi 5 without active cooling will throttle. If it does, revert.
- `pcie-gen3` — run a real read/write load, not a spot check. A minority of
  NVMe drives negotiate Gen 3 and then fail under sustained I/O.

## Troubleshooting

**`check directory not found: .../checks`** — the tree is flat. Move
`{util,probe,ui}.sh` into `lib/` and the numbered files into `checks/`.

**Everything reports `N/A`** — run with `-v` and read the fingerprint header.
An `unknown` model with an empty root source means the probe could not read
`/proc/device-tree/model` or `findmnt` is missing. pi-tune is behaving
correctly: it will not act on a host it cannot identify.

**`--apply` says "needs root (or use --dry-run)"** — expected. Report is
unprivileged on purpose.

**A check fails with `apt-get install <pkg> failed`** — pi-tune already retried
once after an `apt-get update`, so the package lists were not the problem.
Check the box has a route to the mirrors and that the suite is still published
(an EOL Debian release stops resolving). Affects `zram-swap` (zram-tools) and
`chrony-timesync` (chrony).

**Confirmation prompt shows literal `\n`** — you are in the plain-text
fallback (`--no-tui`, or no whiptail/dialog installed). Cosmetic; the list of
changes is still correct.

**Health gate fired and I declined the rollback** — the backup point is still
there. `sudo ./pi-tune.sh --revert last`.

## Adding a check

See "Writing a check" in [README.md](README.md) for the module template and the
`0`/`1`/`2` detect contract, and [ARCHITECTURE.md](ARCHITECTURE.md) for the
helper set and the rules about module-private state.

Before opening a PR:

```sh
shellcheck -x -s bash pi-tune.sh lib/*.sh checks/*.sh tests/*.sh
./tests/run.sh
./pi-tune.sh --list
./pi-tune.sh --report --no-tui
sudo ./pi-tune.sh --apply --dry-run --only <your-id>
```

The last one is the important one: it must print the diff you expect and write
nothing.

## Tests

`./tests/run.sh` runs every `tests/pt-*.sh` against the repo and prints one line
per file. They need no root, no Pi, and no network — each sources the real
`lib/*.sh` and `checks/*.sh` and drives it with stub globals, so what is asserted
is the shipped code rather than a restatement of it. On success you get counts;
a failing file prints its full output, because that is the run where the
rendered screens are evidence rather than noise.

There is no framework and no fixture tree. A test is a bash script taking the
repo root as `$1`, printing `ok <name>` or `FAIL <name>: got X want Y`, and
exiting nonzero if any assertion failed. `run.sh` needs nothing else from it.

Two rules earn their keep here:

- **Prove the assertion can fail.** Several tests carry an explicit
  discrimination check — `pt-ui.sh` re-runs the pre-fix implementation and
  asserts it *fails* the same assertion. When you add a check, break the code it
  covers and confirm the suite goes red before trusting it green.
- **Extract, don't copy.** `pt-media.sh` pulls the `ROOT_MEDIA` case statement
  out of `lib/probe.sh` with `sed` and `eval`s it, rather than keeping a second
  copy beside a guard. A copy needs a drift guard, and the obvious guard —
  counting the `ROOT_MEDIA=` lines — still passes when a medium is *renamed*,
  which is the one drift worth catching.
- **Source the driver, don't rewrite it.** `pi-tune.sh` guards its entry point,
  so a test sources it and calls its functions. Six tests used to `sed` the
  `main "$@"` line into a temp copy first — a test surface made of a regex on
  the file's last line, which one test had to assert had worked.

`tests/.shellcheckrc` relaxes a handful of checks that are correct for the tool
and wrong for a harness that sources it. It applies to `tests/` only; the tool's
own sources are still linted with the full default set.
