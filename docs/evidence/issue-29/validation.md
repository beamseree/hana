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

The snapshot-only tests do not establish combined AC10. The later isolated composition with #28 completed the [combined AC10 journey](../issue-22-combined/README.md), with both reviewed feature identities pinned and no production changes imported into this branch.

## Review and regression result

Review of `b08b41e` against the pinned base used separate Standards and Spec agents. Standards found no hard violations and suggested safer test preconditions, a mutually exclusive inspection result and a cleanup helper. The first two were applied and rechecked; the two different Store acquisition lifetimes keep explicit close/error handling. No outstanding Standards findings. Spec found no implementation defects or scope creep; combined AC10 was pending at independent review and subsequently passed in the isolated validation state.

The first broad non-native run (97 tests/12 suites) failed five assertions in three existing tests: Accessibility deadline/fallback and two `alreadyOwned` close/reopen failures. All three passed a focused rerun. A second broad run passed the Store checks but again exceeded the Accessibility test's one-second deadline. This is retained as observed timing sensitivity, not silently discarded or attributed to a proven cause.

After review fixes, grouped non-native regression passed: 92 tests in 11 suites, then all 5 `DisplayPlacementTests` alone. Commands:

```sh
xcrun swift test --skip 'NativeEditingTests|MacInteractionTests|DestinationInteractionTests|ResultIconInteractionTests|SearchResponsivenessTests|DisplayPlacementTests'
xcrun swift test --filter DisplayPlacementTests
```

These are 97 non-native tests with the native exclusions above; the earlier broad concurrent results were not clean. No unrelated deadline/Store lifetime implementation was changed for this ticket.

## Signed fixture identity

Reviewed source commit: `f65db15499a7d4b1eb660c3cc726fd1ed236eb79` (subsequent evidence-only commits do not change code). macOS 26.4.1 (25E253), Apple Swift 6.3.3, GRDB 7.11.1. `./scripts/build` passed release compilation, Info.plist lint and strict ad-hoc signature verification. Bundle identifier `com.beamseree.hana`; no TeamIdentifier. Worktree-local binary SHA-256: `5ed5a698d0887b5ed907a1eba45b8f276011c2c783229102209663fab63c3409`.

Both snapshot harness tests passed against `build/Hana.app/Contents/MacOS/Hana` using `HANA_EXECUTABLE`, and the [reproducible fixture script](run-fixture.py) generated [the raw signed fixture transcript](signed-fixture.jsonl), including actual linked SQLite identity/effective settings and ordinary fresh-process reopen equality. Run the script with the binary path and a genuinely new fixture parent path. [Check excerpts](check-results.txt) retain failures and passing grouped/signed results. This binary was executed only with `--collection-fixture`.

Final independent verification used explicit `--no-parallel` with the five native exclusions and passed all 97 non-native tests in 12 suites in one run (15.423 seconds). Earlier concurrent failures remain recorded above.

## UUID validation correction — 2026-10-14

A subsequent independent review found one P2: lowercase persisted note/task IDs passed UUID parsing, but Store's case-sensitive lookups bind canonical uppercase UUID strings. Inspection could report a usable snapshot whose listed records could not be edited by ID. Source commit `57a756aad05549eb5207a34b00c3b75d1d5fd8d0` now requires each persisted note/task ID to equal its parsed UUID's `uuidString`. Rejection preserves the snapshot; no normalization or schema migration is performed.

TDD added lowercase note and task cases with valid receipt foreign keys and an updated database checksum. Before the fix both cases failed inspection/list/reopen rejection expectations (eight assertions); afterward all 20 candidate cases pass. A positive regression verifies ID-specific note/task reads, pin/title mutations in a disposable reopened Store and an unchanged original snapshot. All six snapshot test functions pass. [Red/green and verification excerpts](uuid-regression-tests.txt).

Independent verification of this source: signed release build and strict signature checks pass; the complete non-native suite passes **98 tests in 12 suites** with `--no-parallel` and the same five native exclusions. `HANA_EXECUTABLE` points to the rebuilt signed fixture binary; SHA-256 `f72846cec9ed04744494bc528f812359668257e87bf4cc82adaa8e6223f2153e`. This identity supersedes the earlier signed build for the corrected source.

Separate Standards and Spec reviews of `c1bd4ff...57a756a` found no remaining findings and confirmed the P2 resolved. The refreshed [combined AC10 report](../issue-22-combined/README.md) pins this source plus #28 `0592aab` and records **107 non-native tests in 15 suites** passing, including the signed restart/export/snapshot/reopen journey. No native UI, install, personal-store mutation, PR merge or issue closure occurred.
