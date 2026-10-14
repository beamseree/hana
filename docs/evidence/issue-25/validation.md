# Issue #25 validation: Edit, pin, archive and restore saved notes

2026-10-14. Part of #22 (AC3; note portions of AC2 and AC8–AC10). The design and decisions are in the [technical design](../../technical-design.md#note-editing-and-organization--issue-25). Same environment as [#24](../issue-24/validation.md#environment-and-identity): macOS 26.4.1, arm64, Swift 6.3.3, GRDB 7.11.1, system SQLite 3.51.0. Built from the branch rebased onto main `f4d7fd0` (after #39).

## Results

| Criterion | Evidence | Result |
| --- | --- | --- |
| Content update, pin, archive/restore; item/Notes/Archive/all-record queries; exact Unicode/Markdown; title from first nonempty line | `contentEditReplacesTheExactBodyAndAdvancesContentEditedTimeAndRevision` (Thai, decomposed accent, emoji, CRLF, U+2028, leading blank lines; byte-compared; reopened); `archiveHidesAndRestore…`; `allRecordsAndTheSearchProjectionCoverArchivedNotesOnlyWhenEligible` | Met. |
| Creation time immutable; content edit advances content-edited/updated time and revision; pin/archive keep content-edited time; Notes sort pinned → content-edited desc → ID | `contentEdit…`; `pinsComeFirstThenMostRecentlyContentEditedThenStableIDAndPinningKeepsContentEditedTime` (equal-time ID tie, edit reorders, unpin, reopen); `pinnedNotesAndArchiveEachOrderByTheirTimeThenStableID` (order inside the pinned group; Archive by archive time with an equal-time ID tie) | Met. |
| Archive/restore keeps body, pin, content-edited time; archived readable via `note(id)`/`allRecords`; restore before edit/pin; no permanent deletion | `archiveHidesAndRestoreReturnsTheNoteWithBodyPinAndContentEditedTimeIntact` (edit/pin refused with `archivedNote` even when the value already holds; creation time after restore; reopen) | Met. No delete command exists. "Exportable" means available through `allRecords`; export itself is #28. |
| Revision/generation checked at execution; competing commands cannot overwrite later state; invalid commands atomic; already-satisfied no-ops; stale preconditions fail | `competingCommandsOnOneRevisionLetExactlyOneWinAndNeverOverwriteIt` (12 edits + archive + pin concurrently on one revision: exactly one wins, 13 `staleRevision`; late edit cannot undo archive); `alreadySatisfiedCommandsAreNoOpsButStaleOrInvalidOnesFailWithoutChange` (no-op keeps revision and updated time; stale fails even when satisfied; blank, missing, ahead-of-current; byte-different equal text is an edit); `failedTransitionsRollBackAndOldGenerationsCannotChangeNotes` | Met. |
| Committed title/text projection with explicit archive eligibility, excluded by default; no Search bar wiring, autosave or editor | `allRecordsAndTheSearchProjection…`; observation test below. No UI, Search or app-launch file changed. | Met. |
| Each transition, query/sort, timestamp/no-op, conflict, committed observation, fresh-process persistence on real temporary SQLite; targeted rollback; harness demonstration/evidence | `observationsFollowCommittedTransitionsAndNeverShowRolledBackOnes` (Notes, Archive and projection observations; a failed attempt before every commit; values are always committed states and converge); `failedTransitions…` (injected failure and a real SQLite CHECK violation, code 19, for all four commands; nothing consumed); harness `editPinArchiveAndRestorePersistAcrossFreshProcesses`, `killedNoteChangeIsAllOrNone` × {edit, pin, archive} × {before, after commit} (SIGKILL), `aFailedEditLeavesNoTraceInStorageOrOutput` (sentinel absent from database, sidecars and output); [harness demonstration](harness-demo.txt) | Met for normal restart and process crash. Restore was not kill-tested separately; it uses the same update path as archive. |

## Test runs

- Source for every recorded run: `a0ea196` (clean tree). [Build](build.txt): signed ad-hoc `com.beamseree.hana`.
- Full deterministic suite, `xcrun swift test --no-parallel`: 85 tests in 12 suites passed (66 before this change, 19 new or extended), 10.2 s. [Output](full-tests.txt).
- Harness suite against the signed release binary: 8 tests passed, 13 cases with the kill matrix. [Output](signed-harness-tests.txt).
- An earlier run on the uncommitted change, and again on an untouched checkout of `f4d7fd0`, failed only `NativeEditingTests.lateResultsPreserveEditorSelectionUndoAndInputPosition`: `NSApp.keyWindow` was nil because the test process couldn't take key focus in that desktop session. The recorded run above passed it. It is environmental and independent of this change.

## Decisions and limitations

- An archived note refuses edit and pin with `archivedNote` even when the requested value already holds. This is the literal "restore before editing body or pin" rule; the no-op rule applies to archive/restore themselves.
- Timestamps come from the Store clock when the command is submitted. They aren't clamped to be monotonic, so a wall-clock step backwards could give an edit an earlier content-edited time.
- Tasks, export (#28) and snapshots (#29) are not implemented. `allRecords` holds notes only until #26.
- Process-crash and restart evidence only, not power-loss evidence, as in #24.
