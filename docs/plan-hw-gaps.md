# Plan - close the hardware gaps on pi3b-DNS1

Status: **not started**. Written 2026-09-07 against `pi-tune` on `dev`.
Everything here is a box exercise, not a code change. Code changes only happen
if one of these finds a defect.

Scope decided by Joe: every gap in ARCHITECTURE.md's "Not verified" list plus
the two smaller ones, **except anything needing a Pi 5**. `pcie-gen3` and NVMe
root stay open and stay recorded.

One block at a time, output pasted back before the next. A block that changes
state goes alone.

## Order, and why

Safest and most independent first. The two with real risk are last but one, and
nothing reboots until everything else has passed.

### 0. Reconnaissance (read-only)

Which interface carries the SSH session (gates step 3), whether
`/etc/docker/daemon.json` is really absent, the root line in `/etc/fstab`, and
the zram state. Read-only, so it can be one block.

### 1. Restore a modified file from the `files/` mirror

The highest-value gap. Every revert so far deleted a created file or reset unit
state; putting original bytes back has never run on hardware.

Manufacture it: write a `/etc/docker/daemon.json` carrying a setting of Joe's
own, apply `docker-log-caps` so it merges into an **existing** file, revert, and
compare against a copy taken before. Byte-identical or the path is broken.

### 2. The drift guard, on a real file

Straight after step 1, and it reuses the same file. Apply, then edit the file so
it no longer matches `post.sha256`, then revert. Expect skip-and-warn and the
edit still on disk - never a clobber.

### 3. `wifi-powersave` apply

Never applied. It reloads NetworkManager, which is guarded. **Only if step 0
shows the session on `eth0`.** If it rides `wlan0`, skip and record why - the
health gate cannot honestly judge an interface it just dropped the operator
through.

### 4. The Revert screen

`screen_revert` is the one phase-4 screen with no hardware verification, and it
is the screen that writes. Undo a tune through the TUI rather than `--revert`.

### 5. The health gate firing

It has passed three times and never fired. Provoke it with a throwaway check
module dropped in `/tmp/pi-tune/checks/` (never committed) whose `check_apply`
stops `docker`. Docker, not ssh - the gate must not be tested on the unit
carrying the session. Rigged input, real code path, deleted afterwards.

### 6. `root-noatime` apply - the boot-critical one

`/etc/fstab` reads `OK`, so the apply path is unreachable without first removing
`noatime` from the root line. A malformed fstab means the box does not boot.

Guards, all mandatory:
- copy `/etc/fstab` aside before touching it, outside the backup tree
- `findmnt --verify` after every edit, before anything reboots
- `mount -o remount /` to prove the line is accepted by the running kernel
- no reboot until step 8

### 7. `zram-swap` apply

Also reads `OK`. Reaching it means disabling zram first. Reversible, no boot
risk, so it follows the fstab work rather than leading it.

### 8. The Reboot row, `cmdline_add` under schema 2, and the reboot

`usb-autosuspend` is `DONE`, so the finish screen has never had reason to offer
`Reboot`. Revert it, re-apply it through the TUI, and the row should appear -
which also re-proves `cmdline_add`'s vfat write under the schema-2 backup layout,
the one thing the phase-2 plan wanted a fresh apply for.

Choose `Exit`, verify `cmdline.txt` on disk, and only then reboot deliberately.
After the reboot: `/proc/cmdline` carries the token and `findmnt -no OPTIONS /`
still reads what step 6 left.

## Out of scope

- `pcie-gen3`, NVMe root, anything Pi 5. Stays in ARCHITECTURE.md as open.
- Firing the health gate on `ssh`, `sshd` or `NetworkManager`.
