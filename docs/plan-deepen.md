# Plan - deepen the registry, the revert walk, and the test seam

Status: **step 3 in progress**. Written 2026-09-07 against `dev`.
From the architecture review of the same date. Candidates 1-3 of six; 4-6 are
not in scope here.

Vocabulary is the `/codebase-design` glossary - module, interface,
implementation, depth, seam, adapter, leverage, locality. Domain terms come
from ARCHITECTURE.md: check module, the three-state detect contract, rollback
point, schema 1/2, drop-in, guarded units, health gate.

Order is forced by dependency: 3 gives 1 and 2 a real test surface, so it goes
first even though it is the smallest.

Each step ends green: `shellcheck -x -s bash pi-tune.sh lib/*.sh checks/*.sh
tests/*.sh && ./tests/run.sh`, plus a mutation run proving the new assertions
can fail. One commit per step.

---

## Step 3 - make the driver sourceable

`pi-tune.sh` ends in `main "$@"`. Six of twelve tests reach its functions by
`sed`-deleting that last line into a temp copy and sourcing the copy. The test
surface is a text transformation: `tests/pt-revert.sh:25` even guards the
regex, because a rename of the last line would silently turn six test files
into no-ops.

Change: guard the entry point.

```sh
[[ ${BASH_SOURCE[0]} == "${0}" ]] && main "$@"
```

Then each of the six sources `pi-tune.sh` directly and deletes its `drv=`,
its `sed`, and the temp file from its `trap`.

The invariant this must not break: running the script still runs. CI asserts
`--list` and `--report --no-tui`, and both must keep working, as must a bare
`./pi-tune.sh` on a TTY.

Test: the guard itself needs a check that can fail. Assert that sourcing the
driver defines `apply_ids` and produces no output - a driver that still ran
`main` would print the report header.

---

## Step 1 - collapse the check registry into one module

Seven arrays (`C_ID C_TITLE C_RISK C_FILE C_WHY C_IMPACT C_STATE`) declared at
`pi-tune.sh:36`, built in one place, and indexed by position at fourteen. A
one-element skew makes `index_of` return an index that `apply_ids` uses against
`C_FILE`, so the wrong check module is sourced under the right label. Nothing
validates lengths. There is no reset, so `scan_checks` twice doubles the
registry - the tests know this and hand-clear all seven names inline.

Interface:

| call | returns |
|---|---|
| `registry_load` | scans `CHECK_DIR`, honours `ONLY`, replaces any previous contents |
| `registry_ids` | ids in load order, one per line |
| `registry_get <id> <field>` | one field: title, risk, file, why, impact |
| `registry_state <id>` | the detect result, 0/1/2 |
| `registry_set_state <id> <rc>` | after a re-detect |
| `registry_has <id>` | rc 0/1, replacing `index_of` at its two guard sites |

The arrays stay - they become implementation, private to the module, keyed by
id rather than reached by position from outside. Positional indexing survives
only inside the registry, where a skew is one function's problem.

`do_apply:235-242` and `screen_select:745-752` are byte-identical: the same
eight-line pending/items build. Both become one call.

Test: `tests/pt-registry.sh`, new. Load a fixture check dir, assert ids come
back in order, a field round-trips, an unknown id is refused rather than
returning a neighbour's field, `registry_load` twice does not double, and
`--only` filters. Mutation: return a neighbour's field on an unknown id, and
make load append instead of replace - both must fail.

---

## Step 2 - one revert walk, two schemas behind it

`_revert_v1` (439-500) and `_revert_v2` (507-603) run the same five phases.
The restore/delete/rmdir loops are near-verbatim; v1 also carries a literal
copy-paste artefact, the same comment and `BACKUP_DIR="$dir"` assignment twice,
four lines apart.

v1 is missing two things v2 has: the drift guard and the `sysctl.pre` replay.

**Corrected while implementing.** Those gaps are not reachable on real schema-1
points, and the review said otherwise. `_drifted` returns "not drifted" when no
hash was recorded, and schema-1 backups predate `post.sha256` and `sysctl.pre`
entirely - they carry neither, so both guards degrade to no-ops there whichever
walk runs. The case for this step is the duplication and one marker rule, not a
live correctness fix.

Shape: one `revert_subtree <moddir> <id>` walk, and a schema adapter that says
which subtrees to walk in what order.

| schema | adapter yields |
|---|---|
| 1 | one subtree, the run directory itself, `--only` refused |
| 2 | one subtree per module, reverse apply order, already-reverted skipped |

Two adapters justify the seam. The marker rule moves into the walk, so v1 stops
having its marker written by `do_revert` while v2 writes its own.

**This is a behaviour change, not only a refactor**, and it was flagged as such
before approval: a schema-1 revert that today overwrites a drifted file will
begin skipping it with a warning. That is what every other revert path does.

Test: extend `tests/pt-backup2.sh`, which already drives the real `do_revert`
against both schemas. Add a schema-1 point with a drifted file and assert it is
skipped, and a schema-1 point with `sysctl.pre` and assert the value is
replayed. Both assertions must fail against today's `_revert_v1` - that is the
control, and it is what proves the deepening carried the guards over.

## Out of scope

- Candidates 4, 5, 6 from the review.
- Any change to the three-state detect contract.
- `CONTEXT.md` - to be started if these steps settle domain terms worth naming.
