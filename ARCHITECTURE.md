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
variables and up to six functions; the driver sources it into its own shell.
No subprocess, so a module gets the probe globals and the backup plumbing for
free and can leave state behind (`require_reboot`, `require_manual`) that the
driver reads afterward.

Isolation is by reset, not by subshell. `load_check()` unsets every hook
function, reinstalls safe defaults, clears `CHECK_ID`/`CHECK_TITLE` and sets
`CHECK_RISK=medium`, then sources. A module that omits `check_revert` gets the
no-op — never the previous module's. The price of sharing one shell is that a
module can clobber a driver global. Module-private state is prefixed with `_`
(`_jconf`, `_gov`, `_unit`, `_candidates`) and modules never assign to a `C_*`,
`PI_*`, `HAS_*`, `ROOT_*` or `NEEDS_*` name.

## The three-state detect contract

`check_detect` returns a state, not a boolean:

| rc | Meaning | Report | Offered in checklist |
|----|---------|--------|----------------------|
| 0 | Condition already satisfied | `DONE` or `OK` | no |
| 1 | Applies here and is not satisfied | `TUNE` | yes |
| 2 | Does not apply to this host | `N/A` (hidden unless `-v`) | no |

The report shows four states against these three return codes. `DONE` and `OK`
are both rc `0`, split on whether the id appears in the `applied.list` of a
rollback point that has not been reverted — `applied_index` builds that map.
The split is presentation only and deliberately **not** a fourth return code:
making it one would push the question "did we do this?" into all twelve modules,
which cannot answer it.

The default installed by `load_check` is `2`. A module that cannot positively
confirm the condition must return `2` rather than guess — the whole point of
the split is that "I could not tell" and "it is fine" are different answers,
and only one of them is safe to act on. `root-noatime` returning `2` when
`/etc/fstab` has no root entry is the pattern.

## Lifecycle

**Report** (`--report`, default, no root):
`ui_init` -> `probe_host` -> `scan_checks` (source each module, run
`check_detect`, `check_why` and `check_impact`, record state) -> `print_report`.

**Apply** (`--apply`, root, or `--dry-run` without):
report, then `do_apply`:

1. Collect state-1 checks; `low` risk pre-ticked, `medium`/`high` unticked.
2. In TUI mode only, a review screen: every pending change with its
   `check_why` and `check_impact`. The TUI clears the screen, so the report is
   gone by the time the checklist opens; on the plain path the report is still
   visible and the screen is skipped as duplication.
3. `ui_checklist` -> selection, then a `ui_yesno` confirmation offering
   Apply/Back. Back reopens the checklist with the selection carried in as the
   new defaults, so a second thought costs one keypress rather than the whole
   selection. Cancel on the checklist, or selecting nothing, exits.
4. `new_backup_dir` — `/var/backups/pi-tune/<YYYYmmdd-HHMMSS>/` plus `manifest`.
5. `health_snapshot` — copies `CRITICAL_UNITS` (units already active at probe
   time) into `ACTIVE_BEFORE`.
6. Per selected id: append to `applied.list` **before** calling `check_apply`,
   re-source the module, run it. A module that dies mid-write is already
   recorded and stays reachable by `--revert`.
7. `health_verify` — any unit in `ACTIVE_BEFORE` no longer active triggers an
   offer to roll the whole run back.
8. Print `NEEDS_MANUAL` items and the reboot flag.

**Revert** (`--revert TS|last`, root):
`scan_checks` runs first — revert needs the registry to map an id back to a
file. `BACKUP_DIR` is pointed at the rollback point so modules can read back
sidecars they wrote during apply (`idle-services` stores the unit list it
disabled). Then, in order:

1. `check_revert` for each selected id.
2. Restore every file under `modules/<id>/files/` to its mirrored absolute path.
3. Delete every path in that module's `created.list`.
4. `rmdir` every path in its `created.dirs`, deepest first.
5. `systemctl daemon-reload`, and `sysctl --system` if any sysctl drop-in was
   part of the selection.
6. `check_revert_post` for each selected id.
7. Write `modules/<id>/reverted`, so `applied_index` stops reporting it `DONE`
   and it is not offered for undo twice.

The phases run **across** the selected modules, not one module end to end.
Doing a module completely before starting the next would run its post hook — a
reload — over another module's not-yet-restored config, which is the exact
mistake the two-hook split exists to prevent.

### Why revert has two hooks

Undo work splits by which side of the file restore it has to happen on, and a
module that guesses wrong reports success while leaving the change in force.

`check_revert` runs **before** restore, for anything that needs the applied
config still on disk — `systemctl disable --now pi-tune-governor.service` can
only stop a unit whose unit file has not been deleted yet.

`check_revert_post` runs **after** restore, for anything whose whole purpose is
to make a running service notice that the config changed. `journald-cap`
restarts journald; in the pre hook it would reload the very cap being removed
and hold it until the next restart. `root-noatime` remounts `/`; in the pre
hook it would re-read the noatime fstab mid-revert. `wifi-powersave` needs
both: the pre hook disables its own unit, the post hook reloads NetworkManager
once the drop-in is gone.

The rule of thumb: **stopping** something goes in `check_revert`, **reloading**
something goes in `check_revert_post`.

Step 4 uses `rmdir`, not `rm -r`. A directory `install_file` created but that
someone else has since put a file in is left alone — pi-tune only ever removes
a directory it made and that is still empty.

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
| `ROOT_SRC`, `ROOT_FSTYPE`, `ROOT_IS_SD`, `ROOT_IS_USB` | `root-noatime`, `usb-autosuspend` |
| `ROOT_MEDIA` | `journald-cap`, `zram-swap`, report header |
| `HAS_NVME` | `pcie-gen3` |
| `SDR_TYPE`, `HAS_SDR` | `cpu-governor`, `dvb-blacklist`, `usb-autosuspend` |
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
├── manifest              host, model, pi-tune version, schema=2
├── applied.list          check ids in apply order, written before each attempt
└── modules/
    └── root-noatime/
        ├── files/            mirror of the originals THIS module overwrote
        │   └── etc/fstab
        ├── created.list      absolute paths that did not exist before
        ├── created.dirs      directories install_file created, deepest first
        ├── post.sha256       what the module left on disk
        ├── reverted          written when this tune is undone
        └── idle-services.list  module-private sidecars land here too
```

`files/` still mirrors absolute paths, so restore is still a blind walk — it
just starts one level down, inside the module that wrote them. Reverting one
tune walks `modules/<id>/`; reverting a whole run walks its modules in reverse
apply order.

The per-module level exists because per-tune revert is exactly the requirement
that something knows which module wrote what. It costs almost nothing in the
apply path: `backup_file`, `record_absent`, `record_new_dirs` and every module
sidecar resolve through `BACKUP_DIR`, so pointing it at `modules/<id>` around
each `check_apply` files all of them correctly with **no change to any helper**.

`post.sha256` is the guard the split makes necessary. Reverting tune A after a
later tune B changed the same file would silently undo B. Nothing writes the
same path twice today — `cmdline.txt` only from `usb-autosuspend`, `config.txt`
only from `pcie-gen3`, everything else a private drop-in — so the hazard is
latent, and per-tune revert is what makes it reachable. On revert, a file whose
current hash does not match what the module left is **skipped with a warning**,
never clobbered, on both the restore and the delete path. The delete path is the
worse of the two: removing a file someone else has since edited destroys their
work rather than ours. A partial revert the operator is told about beats a
silent wrong one.

**Schema 1 rollback points still exist and still revert.** A manifest with no
`schema=2` line means the pre-2 layout — one `files/` tree at the run root, no
record of which module wrote what — and takes the old whole-run walk.
`--only` is refused there rather than silently reverting everything. Such a
revert writes `<TS>/reverted` at the run level, since there is no module level
in it to mark; `applied_index` skips the whole run when it sees that. Without
it an undone tune keeps counting as applied and can still be reported `DONE`.

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

## Verified on hardware

A test proves the code does what it was written to do. Only a box proves it was
the right thing to write. This records which is which, so the next session does
not re-run what is settled or assume what is not.

**pi3b-DNS1** — Pi 3B+, Debian trixie, root on a USB-attached SSD (`/dev/sda2`),
Docker running, `wlan0` associated alongside `eth0`, no SDR. 2026-09-07.

Exercised end to end:

- Probe: `ROOT_MEDIA` derived and rendered on both the report and the checklist
  header; `usb-autosuspend` gating on `ROOT_IS_USB` with `HAS_SDR` unset.
- `cmdline_has` reading a token already present in `/boot/firmware/cmdline.txt`.
- Apply on three checks (`journald-cap`, `idle-services`, `docker-log-caps`):
  backup taken, `applied.list` written, health gate passed, `require_manual`
  surfaced to the operator, rollback point printed.
- Detect after apply: `journald-cap` reads its own drop-in back as `OK`.
- Revert, both paths it can reach here: unit state restored to *exactly* the
  prior state (`ModemManager` back to enabled **and** active, with both its
  `multi-user.target.wants` link and its D-Bus alias recreated), and a file that
  did not exist before the run deleted via `created.list` rather than left
  behind empty.
- TUI: review, checklist and confirm dialogs; the scroll flag passed only on
  overflow, confirmed by its absence on a one-change review.
- The five screens (plan phase 4), walked as root and again unprivileged: host,
  status, selection, the three-row confirm, and finish. Unprivileged, the
  confirm offers `Dry run` and `Back` only. `NEEDS_MANUAL` reaches the operator
  on the finish screen instead of scrolling past on stdout, which is what it was
  added for.
  Two things only the box could show, both since fixed: the dry-run diff printed
  to the terminal and was painted over by the next dialog a moment later, and
  the text captured from `apply_ids` still carried the colour escapes, which
  whiptail drew as `^[[32m`. Colour is decided once at load from `[[ -t 1 ]]`,
  so capturing it inside a run that began on a terminal keeps it — no test that
  runs off a terminal can see this, because there the escapes are empty strings.
- Four states (plan phase 1), on the pair that makes them distinguishable:
  `journald-cap` reads `DONE` because pi-tune capped it, `root-noatime` reads
  `OK` because the image already mounts that way. A three-state design would
  have shown both as the same thing.
- `applied_index` needs no root: `/var/backups/pi-tune` is readable by the
  invoking user, so `DONE` survives an unprivileged `--report`.
- The unprivileged degradation in `docker-log-caps`' `check_why` — with
  `/var/lib/docker/containers` unreadable at `0710`, the size parenthetical is
  dropped whole rather than printed empty. Previously only asserted in tests.
- **`cmdline_add`, the one boot-critical write in the repo.** Rollback point
  `20260906-233556` applied `usb-autosuspend`, and its backup holds
  `/boot/firmware/cmdline.txt` *without* `usbcore.autosuspend=-1` while the live
  file carries it, appended with a single space and otherwise byte-identical.
  So the write ran on vfat, `install_file` snapshotted the original first, and
  the box has rebooted since with the kernel parsing the result — `/proc/cmdline`
  carries the token. Not covered by that: the dry-run diff path, and the
  `modprobe` drop-in fallback for boards with no `cmdline.txt`.

- **Per-module backups and per-tune revert (plan phase 2).** Run
  `20260907-155827` applied `docker-log-caps` and `idle-services` together and
  wrote `schema=2` with both under `modules/`, no run-level `files/` or
  `created.list`. `idle-services.list` — a sidecar no code repoints — landed in
  its own module directory purely by resolving through `BACKUP_DIR`, which is
  the "no change to any helper" claim holding on real hardware; at the run root
  it would have made that tune's revert silently find nothing. Reverting only
  `docker-log-caps` removed `daemon.json` and left `ModemManager` `disabled` /
  `inactive`, and afterwards the same run reads `docker-log-caps` as `TUNE` and
  `idle-services` as `DONE`.

- **`ui_menu` (plan phase 3).** Against real whiptail: the tag survives the
  `3>&1 1>&2 2>&3` capture while the dialog draws on the terminal, a middle row
  returns its own tag rather than an off-by-one, Cancel gives `1` and Esc `255`
  with no stale tag on either, and the overflow budget shrinking with list
  height triggers the title hint at 30 lines against a 7-row menu. PgDn moves
  the body of a menu — worth recording, because a menu's list is focusable and
  `--msgbox`, where focus sits on the button, was the case measured earlier.

Closed 2026-09-07, in a campaign to clear this list (`docs/plan-hw-gaps.md`):

- **Restoring a modified file from the `files/` mirror.** An `/etc/docker/
  daemon.json` written by hand with 4-space indent, overwritten by
  `docker-log-caps`' merge, then reverted: byte-identical to a copy taken
  beforehand. A restore that merely re-serialised valid JSON would have shown
  as a different hash, which is why the fixture was indented unusually.
- **The `post.sha256` drift guard, on a real file.** The same file edited after
  the apply: revert warned, named it, and left the edit on disk.
- **`wifi-powersave` apply**, and the defect it exposed - it applied live and
  persisted but reverted only the persisted half, so the status table read `OK`
  while the setting was still in force. Now symmetric, and verified both ways:
  radio `off` and `DONE` after apply, `on` and `TUNE` after revert.
- **The Revert screen**, the one phase-4 screen that writes. Listed per-tune and
  whole-run entries, undid only the ticked one, returned to host.
- **The health gate firing, and its rollback.** Provoked with a throwaway module
  that stops `docker.service`. The gate caught it despite systemd warning that
  `docker.socket` was still active, the rollback dialog appeared, and the
  module's `check_revert` restarted docker with its containers.

- **`root-noatime` apply and revert**, the boot-critical file. `/etc/fstab` had
  `noatime` removed by hand to reach the path, applied, reverted, and restored -
  `findmnt --verify` clean at every step and the file byte-identical to a copy
  taken first.
- **`zram-swap` apply and revert**, reached by `swapoff`-ing the stock zram
  rather than disabling the generator unit. Also caught a module *failing*
  mid-apply, which had never run either: `applied 0 of 1`, the error named, and
  a rollback point still written for the partial changes.
- **The health gate's rollback**, above.
- **The finish screen's `Reboot now` row**, which had never appeared - the only
  reboot-requiring check was already `DONE` before the screens existed.
- **`cmdline_add` under schema 2.** `usb-autosuspend` reverted and re-applied:
  the token appended with a single space, the rest of the line byte-identical,
  and `modules/usb-autosuspend/files/boot/firmware/cmdline.txt` holding the
  pre-token original. The vfat backup ran before the write. This was previously
  inferred from a backup an older version had taken; it is now observed.

Three findings that are not bugs but will mislead a reader who does not know:

- **`zram-tools` cannot initialise `/dev/zram0` on an image that already ships
  zram.** `mkswap: cannot open /dev/zram0: Device or resource busy` - the stock
  `systemd-zram-setup@zram0.service` holds it. Unreachable in normal use, since
  `check_detect` returns satisfied on any box that already has zram, but the
  apply path is not safe to force there.
- **`zram-swap`'s `PERCENT=50` did not size the device.** zram-tools reused the
  905 MB device the generator had already made rather than resizing it, so the
  Effect text's "half of physical memory" was not what the box got.
- **`usb-autosuspend` reads `OK` immediately after being reverted.**
  `check_detect`'s last fallback reads
  `/sys/module/usbcore/parameters/autosuspend`, and the running kernel still
  carries the parameter the *previous* boot's cmdline gave it. The apply never
  touched the runtime, so this is the detect reporting effect rather than
  configuration; it self-corrects on reboot. Deliberately left as is - the
  alternative is a detect that ignores a genuinely disabled autosuspend.

Not verified, and not inferable from the above:

- **Anything Pi 5.** `pcie-gen3` has never returned anything but `N/A`, and NVMe
  root is inferred from that check existing rather than observed. This is the
  only item left on this list.

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
- **There is no UAS quirk check**, though `8a9744c` left a note planning one.
  The observed evidence says not to build it yet. On pi3b-DNS1 the kernel
  refuses UAS outright — `the driver for the USB controller does not support
  scatter-gather which is required by the UAS driver` — and binds `usb-storage`
  on every boot. That is the `dwc_otg` controller, so it holds for every
  pre-Pi-4 board, and a `usb-storage.quirks=` token there would be a no-op
  against a driver that was never going to load. The check would only mean
  anything on a Pi 4/5, where `xhci` does support scatter-gather and `uas` binds
  for real — and no Pi 4/5 here boots from USB, so there is nothing to observe
  and nothing to verify a fix against. The one adapter with real data
  (`7825:a2a4`, OWC PA023U3) is on the board that cannot use UAS at all, so it
  is not evidence of a bad bridge; it is evidence of nothing. A known-bad quirk
  list with no confirmed-bad entries matches nothing and only costs a boot arg.
  Build it when a Pi 4/5 boots from USB here and `uas` actually misbehaves.
