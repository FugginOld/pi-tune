# Plan — menu-driven TUI, four states, per-tune revert

Status: **phases 1-2 done** (`aed6f0d`, and phase 2 pending its box check).
Written 2026-09-07
against `201f09c`.

Execute phases in order. Each phase ends green: `shellcheck -x -s bash pi-tune.sh
lib/*.sh checks/*.sh tests/*.sh && ./tests/run.sh`, plus the hardware check named
in that phase. Do not start a phase before the previous one's box check has come
back, per the standing rule about verifying as you go rather than in a batch.

## What is being built

Five screens, replacing report-then-checklist as the interactive entry point:

1. **Host** — model and probe details. Buttons: `Tune`, `Revert`, `Quit`.
   `Revert` appears only when a revertable tune exists.
2. **Status** — every check with `TUNE` / `DONE` / `OK` / `N/A`. Read-only.
3. **Revert** — checklist of individually revertable applied tunes.
4. **Select** — checklist of `TUNE` items with Why/Effect, then a confirm with
   `Apply` / `Dry run` / `Back`.
5. **Finish** — `Reboot` / `Exit`, reboot offered only when `NEEDS_REBOOT=1`.

Three decisions taken 2026-09-07, recorded so a later reader does not relitigate
them:

- **Revert is per tune**, not per run. This is the expensive one; see Phase 2.
- **Four states, not three.** `DONE` means pi-tune applied it and it is
  revertable; `OK` means the box was already that way. `root-noatime` reads
  satisfied on pi3b-DNS1 and pi-tune never touched it — collapsing those two
  would have the tool claim credit for the distro's defaults and would leave the
  Revert page filtering the difference back out anyway.
- **Dry run is a third button on the confirm**, via `--extra-button`, not a row
  in the checklist. The checklist stays a list of tunes; the mode choice sits at
  the moment of commitment.

## Invariants that constrain this

From ARCHITECTURE.md, all still binding. Breaking any of these fails CI or the
fleet path:

1. **Report mode never needs root and never writes.** CI asserts
   `--report --no-tui` as an unprivileged user.
2. **`--fleet` ships the tree over SSH and runs `--report --no-tui`.** The menu
   must never appear there.
3. **Every entry point degrades to plain text** over a dumb pipe or in CI.
4. **`--yes` applies only low-risk items.** No flag applies a `high` item
   unattended.
5. **Nothing is written without a backup**; `install_file` aborts if
   `backup_file` fails.

Therefore: **the menu is the default only when interactive** — a TTY with a
backend, i.e. exactly `ui_available` after `ui_init`. Bare invocation without a
TTY keeps today's report behaviour, and `--report` stays an explicit
non-interactive audit. Browsing needs no root; when `EUID != 0` the confirm
screen offers `Dry run` and `Back` only, with the reason stated, rather than
demanding root at launch.

---

## Phase 1 — four states

Smallest independent piece, and Phase 2 depends on it.

`DONE` needs to know what pi-tune applied. That is recoverable from
`applied.list` across every rollback point, but only if reverts are recorded —
a tune applied and then reverted must stop reading `DONE`.

- `applied_index()` in `pi-tune.sh`: scan `$BACKUP_ROOT/*/applied.list`, skip any
  module marked reverted (Phase 2 writes that marker; until then nothing is
  marked and the index is simply every applied id). Populate an associative
  array `APPLIED[id]=<TS of most recent apply>`.
- Extend the state vocabulary where `print_report` and the checklist render it.
  Current mapping is `0 -> OK`, `1 -> TUNE`, `2 -> n/a`. New rendering rule:
  `detect==0 && APPLIED[id] set -> DONE`, `detect==0 otherwise -> OK`.
  **`check_detect`'s three-state contract does not change** — this is a
  presentation split, not a fourth return code. Say so in a comment; a fourth
  rc would ripple into every one of the twelve modules.
- `--list` gains nothing. `print_report` shows `DONE` with the timestamp.

Tests (`tests/pt-states.sh`, new): a fake `BACKUP_ROOT` with two runs; assert
`DONE` for an applied+satisfied id, `OK` for a satisfied id that was never
applied, that a reverted id falls back to `OK`, and that `TUNE`/`N/A` are
unchanged. Mutation: collapse `DONE` and `OK` and it must fail; drop the
reverted-marker check and it must fail.

Box check: `--report` on pi3b-DNS1 must show `journald-cap` as `DONE` (applied
12:49 and kept) and `root-noatime` as `OK` (satisfied, never applied by us).
That is the discriminating pair — it exists on the box already.

---

## Phase 2 — per-module backups

The expensive phase, and the one with real risk. Do not merge it with Phase 1.

### Why it is not small

ARCHITECTURE.md line ~175: *"`files/` mirrors absolute paths, so restore is a
blind walk: for every file under `files/`, strip the prefix and `cp -a` it back.
Nothing needs to know which module wrote it."* Per-tune revert is exactly the
requirement that something knows which module wrote it.

### Layout v2

```
/var/backups/pi-tune/<TS>/
├── manifest            host, model, version, schema=2
├── applied.list        module ids in apply order (unchanged)
└── modules/
    └── <check-id>/
        ├── files/          originals this module overwrote
        ├── created.list
        ├── created.dirs
        ├── post.sha256     what the module left on disk (see hazard below)
        ├── reverted        written when this tune is reverted
        └── <sidecars>      e.g. idle-services.list
```

The blind walk survives — it moves one level down. Reverting one tune walks
`modules/<id>/` exactly as `do_revert` walks a run today. Reverting a whole run
walks its modules in **reverse** apply order.

### Why the diff is smaller than it looks

`backup_file`, `record_absent`, `record_new_dirs` and the module sidecars all
resolve through `$BACKUP_DIR`. Setting `BACKUP_DIR="$RUN_DIR/modules/$id"`
around each module's `check_apply` puts every one of them in the right subtree
**with no change to the helpers**. `do_revert` already sets `BACKUP_DIR` for the
same reason — see its existing comment about sidecars resolving to `/<name>`.

### The hazard this creates

Reverting tune A after a later tune B changed the same file would silently undo
B. No two checks currently write the same path (`cmdline.txt` only from
`usb-autosuspend`, `config.txt` only from `pcie-gen3`, the rest are private
drop-ins), so this is latent rather than live — but per-tune revert is what
makes it reachable, and a silent wrong restore on a mutating path is the worst
failure this tool has.

Guard: record `post.sha256` of each file **as the module left it**. On revert,
if the file on disk no longer matches, something changed it since — warn, skip
that file, and keep going. Per the arbitration rule, the guard stands over the
simplification. Do not make this a hard abort: a partial revert the operator is
told about beats refusing to undo anything.

### Backwards compatibility — non-negotiable

pi3b-DNS1 has three real rollback points in schema 1
(`20260907-124902`, `-144328`, `-144725`; the last two were reverted during
testing, the first is live). `do_revert` must detect a missing `schema=2` in the
manifest and take the old whole-run blind walk. Schema 1 dirs offer no per-tune
revert — the Revert page lists them as one entry each, labelled as a whole run.

Tests (`tests/pt-backup2.sh`, new): apply two fake modules into one run, assert
each lands in its own subtree; revert one and assert the other's files are
untouched and its `reverted` marker is absent; assert a schema-1 fixture still
reverts whole; assert a modified-since file is skipped with a warning rather
than clobbered. Extend `pt-revert.sh` rather than replacing it — it currently
covers the v1 walk and that path still exists.

Box check: apply two tunes in one run, revert only one, confirm the other
survives, then `--report` shows one `DONE` and one back to `TUNE`.

---

## Phase 3 — ui.sh primitives

- `ui_menu <title> <text> <tag> <label> ...` — whiptail `--menu`, dialog
  `--menu`; plain-text numbered fallback mirroring `ui_checklist`'s.
- `ui_confirm3 <title> <text> <yes> <extra> <no>` — `--extra-button`
  `--extra-label`. **Verify the exit codes on the box before relying on them**:
  whiptail is expected to give OK=0, Cancel=1, Extra=3, Esc=255, but that is
  the same class of assumption as `--scrolltext` and it was wrong last time.
  Plain-text fallback reads one of three letters.
- Both go through `ui_overflows` for the scroll flag and title hint, same as
  `ui_msgbox` and `ui_yesno`. Do not pass the scroll flag unconditionally — see
  `1db8af0`: on this whiptail the bar renders only when content already fits.

Tests: extend `pt-ui.sh`. Drive `ui_pick_backend` with a stubbed `have()` as it
already does, assert each backend gets its own flag spelling and that the extra
button is passed. Mutation: swap the exit-code mapping and it must fail.

---

## Phase 4 — wire the screens

`main()` gains an interactive branch. Everything below it stays reachable:

```
main
├─ --fleet / --list / --rollbacks / --revert TS   unchanged
├─ --report                                        unchanged, non-interactive
├─ --yes                                           unchanged, low-risk only
└─ default
   ├─ ui_available  -> screen_host (the new flow)
   └─ otherwise     -> print_report   (today's behaviour, CI's path)
```

Screen functions live in `pi-tune.sh`, not `lib/ui.sh` — `ui.sh` stays a widget
wrapper that knows nothing about checks. Each screen returns a next-screen name;
`main` runs the loop, so Back is a return value rather than recursion.

`--dry-run` on the command line pre-sets the toggle; the confirm screen still
offers all three buttons. `DRY_RUN` stays the single global every helper already
reads — the toggle assigns it, nothing else changes.

Phase 5, finish screen: offer `Reboot` only when `NEEDS_REBOOT=1`, and surface
`NEEDS_MANUAL` entries here rather than only on stdout — `require_manual` output
scrolled past unread until this session proved it reaches the operator.

---

## Out of scope

- Per-tune revert across **runs that touched the same file**, beyond the
  `post.sha256` skip-and-warn. Merging two runs' changes to one file is a real
  problem and this plan does not solve it; it detects it and refuses.
- Any change to `check_detect`'s three-state contract.
- `--fleet` remote apply. Still report-only by construction.

## Open risks

- **`--extra-button` exit codes are assumed, not verified.** Phase 3 verifies
  before building on them.
- ~~`cmdline_add`'s write path is unverified~~ — settled 2026-09-07 from the
  backup of rollback point `20260906-233556`, which holds the pre-token
  `cmdline.txt`. It ran on vfat and the box rebooted on the result. Phase 2 moves
  the backup directory underneath it without touching `install_file`, so the
  next `usb-autosuspend` apply on a fresh board re-proves it under schema 2.
- Schema-1 rollback points exist on a live box. Every `do_revert` change is
  tested against a schema-1 fixture before it ships.
