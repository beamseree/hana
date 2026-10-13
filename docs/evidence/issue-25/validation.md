# Issue #25 validation — Edit, pin, archive and restore saved notes

2026-10-13. Part of #22 (AC3; note portions of AC2, AC8–AC10). Design: [technical design](../../technical-design.md#note-organization--issue-25).

## Status: written without a compiler — not yet built or run

This slice was written in a Linux cloud session with no Swift toolchain (the download host was blocked) and no macOS SDK. **None of the code or tests below has been compiled or run.** Every "Result" is *Not run*. Before merging, on the target Mac:

```sh
xcrun swift build
xcrun swift test --no-parallel --filter 'CollectionNoteOrganizationTests|CollectionNoteHarnessTests'
xcrun swift test --no-parallel   # full regression, including #24's suites
```

Then replace this section with the environment, source commit, test counts and output files, in the format of [#24's record](../issue-24/validation.md).

## Criteria → tests

| Criterion | Tests | Result |
| --- | --- | --- |
| Content update, pin, archive/restore; item, Notes, Archive and all-record queries; exact Unicode/Markdown; title from first nonempty line | `editKeepsExactBytesAndCreationTimeAndAdvancesContentEditedTime` (Thai, decomposed accents, emoji, CRLF, U+2029, NUL, trailing spaces; byte-different but canonically equal bodies are real edits); `archiveAndRestorePreserveBodyPinAndContentEditedTime`; `archiveListsMostRecentlyArchivedFirst` | Not run |
| Immutable creation time; content edits change content-edited/updated time and revision; pin/archive preserve content-edited time; pinned first, then content-edited descending, then ID | `editKeepsExactBytes…`; `pinsSortFirstWithoutPretendingTheWritingChanged`; `equalContentEditedTimesSortByStableID` | Not run |
| Archive/restore preserves body, pin and content-edited time; archived readable; restore before editing body or pin; no deletion | `archiveAndRestorePreserveBodyPinAndContentEditedTime` (edit and pin refused with `archived`, record unchanged) | Not run |
| Revision/generation checked at execution; competing edit/archive cannot overwrite; atomic failure; satisfied commands are no-ops; stale preconditions still fail | `competingEditAndArchiveCannotOverwriteEachOther` (10 rounds, concurrent); `satisfiedCommandsAreNoOpsButStalePreconditionsStillFail`; `failedCommandsRollBackAndStaleGenerationsAreRejected` | Not run |
| Committed title/text projection; archive excluded by default; not wired to Search | `searchTextProjectsCommittedNotesAndExcludesArchiveByDefault` | Not run |
| Committed observations; persistence across restart and fresh processes; targeted rollback; harness demonstration | `observationsFollowEditsPinsAndArchive`; reopen checks in the edit and archive tests; `organizeANoteAcrossFreshProcesses`; `killedEditIsAllOrNone` × {before-commit, after-commit} (SIGKILL) plus an injected `--fail before-commit` archive | Not run |

## Limitations

- Unverified: see Status. Expect possible compile fixes.
- Same process-crash (not power-loss) scope as #24. No Search-bar, editor, autosave or organizer wiring.
