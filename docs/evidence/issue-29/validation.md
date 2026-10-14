# Issue #29 — manual validated collection snapshots

Review baseline: `210e9f34de86d751de6eb80a584cc41cde560ee3` (includes #24–#27).
Scope: [#29](https://github.com/beamseree/hana/issues/29), under revised [#22](https://github.com/beamseree/hana/issues/22). Store and Recovery are the agreed test seams. No capture/organizer UI or production restore is added.

## Capture contract

`CollectionRecovery.createSnapshot` runs off the main actor. Store schedules capture on the existing GRDB pool writer queue using `writeWithoutTransaction`, checks the session generation there, samples UTC capture time, uses `Database.backup(to:)`, closes the destination, and reads the source's immutable all-record state before releasing the queue. Commands serialized before that block are included; commands after it are excluded. The timestamp describes the capture barrier, not the last commit or publication time.

GRDB 7.11.1's `DatabaseReader.swift` explicitly says a generic pool backup may or may not reflect concurrent writes. This implementation instead uses the existing writer barrier and the connection-level online backup. No extra source writer/checkpointer is opened. The [SQLite backup documentation](https://www.sqlite.org/backup.html) describes the online-backup facility; the pinned GRDB source was inspected locally. The source runtime safety choice from #24 is unchanged.

A destination-volume `.incomplete-UUID` directory contains a private `collection.sqlite` and `manifest.json`. The backup switches to DELETE journal mode and closes before validation; any closed orphan SHM index is removed, and a nonempty WAL prevents success. The manifest records format/schema versions, snapshot identity, collection identity, UTC time, capture provenance, counts and SHA-256 of the closed database. An exclusive same-parent rename publishes `snapshot-UUID`, never overwriting an existing package. Failed staging is retained diagnostically, with no automatic retry or retention deletion.

Validation checks supported schema history and exact initial table/index definitions, full SQLite integrity, foreign keys, UTF-8, nonblank notes and single-line tasks, IDs/revisions/pins, independent completion/archive and placement/order invariants, package names and manifest counts/identity/hash/time. Only complete validated packages are usable. Reopening revalidates, creates a new marked disposable root, copies the standalone database, validates the copied bytes, and opens a new Store. It never opens the sole snapshot as a writable Store or replaces an existing root.

## Automated evidence

- Organized fixture: all 7 notes and 14 tasks, exact Unicode/Markdown bytes, note pins/archive, manually reordered/renumbered Inbox and Today, timestamps/revisions and all four task completion/archive combinations compare equal through Store queries after disposable reopen. The source collection is deleted before reopening, proving no source-WAL dependency. A memory-only sentinel is absent from the snapshot payload and manifest.
- Capture test: live nonempty WAL, controlled writer barrier, a later concurrent command, and independent reopen containing exactly the earlier committed note.
- Damaged candidates: truncation, future schema/manifest, count/hash/identity/time/name mismatch, missing manifest, incomplete staging, blank note, mandatory-line-break task, invalid UTF-8, foreign key damage, invalid placement, symlink and missing schema table are rejected. None can be opened as a usable snapshot.
- Controlled failure at staging/capture/close/validation/manifest/publication preserves source and previous copy; retry creates another distinct usable copy. Status ends in `failed`, never `complete`, for failures. Actual owner-read-only destination and exclusive publication collision are also tested.
- Original snapshot bytes remain identical after inspection and after a disposable Store receives a new committed note. The source stays unchanged.
- Fresh-process harness: create, list, inspect and disposable reopen through the production binary; existing `notes` and `tasks` summaries compare equal. Live paths, non-UUID traversal and existing destination roots are refused.

TDD observations are recorded in worktree-local `build/coordination/snapshot-red-1.log` through `snapshot-red-6.log` and their green counterparts. The missing-table regression was observed accepting an invalid snapshot before the schema-structure check; it now rejects it.

## Verification boundary

Ordinary backup/reopen and controlled error handling only. No crash/power-loss recovery guarantee, daily scheduling/retention, background retry, production replacement, generation-pointer journal, general migration or restore UI. Normal Hana UI was not launched, personal storage was not touched, and no installation was performed.

The coordinator withheld native test slots. `NativeEditingTests`, `MacInteractionTests`, `DestinationInteractionTests`, `ResultIconInteractionTests`, and opt-in `SearchResponsivenessTests` are excluded. Report the remaining checks as a non-native regression suite, never a full-suite pass. No app/native wiring changed.

Combined AC10 export + snapshot journey is coordinated separately after both feature commits are available; it is not claimed complete by these snapshot-only tests.

## Review and regression result

Review of `b08b41e` against the pinned base used separate Standards and Spec agents. Standards found no hard violations and suggested safer test preconditions, a mutually exclusive inspection result and a cleanup helper. The first two were applied and rechecked; the two different Store acquisition lifetimes keep explicit close/error handling. No outstanding Standards findings. Spec found no implementation defects or scope creep; combined AC10 remains pending.

The first broad non-native run (97 tests/12 suites) failed five assertions in three existing tests: Accessibility deadline/fallback and two `alreadyOwned` close/reopen failures. All three passed a focused rerun. A second broad run passed the Store checks but again exceeded the Accessibility test's one-second deadline. This is retained as observed timing sensitivity, not silently discarded or attributed to a proven cause.

After review fixes, grouped non-native regression passed: 92 tests in 11 suites, then all 5 `DisplayPlacementTests` alone. Commands:

```sh
xcrun swift test --skip 'NativeEditingTests|MacInteractionTests|DestinationInteractionTests|ResultIconInteractionTests|SearchResponsivenessTests|DisplayPlacementTests'
xcrun swift test --filter DisplayPlacementTests
```

These are 97 non-native tests with the native exclusions above; the broad single-run result is not clean. No unrelated deadline/Store lifetime implementation was changed for this ticket.

## Signed fixture identity

Reviewed source commit: `f65db15499a7d4b1eb660c3cc726fd1ed236eb79` (subsequent evidence-only commits do not change code). macOS 26.4.1 (25E253), Apple Swift 6.3.3, GRDB 7.11.1. `./scripts/build` passed release compilation, Info.plist lint and strict ad-hoc signature verification. Bundle identifier `com.beamseree.hana`; no TeamIdentifier. Worktree-local binary SHA-256: `5ed5a698d0887b5ed907a1eba45b8f276011c2c783229102209663fab63c3409`.

Both snapshot harness tests passed against `build/Hana.app/Contents/MacOS/Hana` using `HANA_EXECUTABLE`, and the [reproducible fixture script](run-fixture.py) generated [the raw signed fixture transcript](signed-fixture.jsonl), including actual linked SQLite identity/effective settings and ordinary fresh-process reopen equality. Run the script with the binary path and a genuinely new fixture parent path. [Check excerpts](check-results.txt) retain failures and passing grouped/signed results. This binary was executed only with `--collection-fixture`.
