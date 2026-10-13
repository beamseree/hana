# Issue #26 validation — Create and transition tasks across Inbox, Today, Completed and Archive

2026-10-13. Part of #22 (AC4; task portions of AC2, AC8–AC10). Builds on #25. Design: [technical design](../../technical-design.md#tasks--issue-26).

## Status: written without a compiler — not yet built or run

Written in a Linux cloud session with no Swift toolchain or macOS SDK. **Nothing below has been compiled or run**; every result is *Not run*. On the target Mac:

```sh
xcrun swift build
xcrun swift test --no-parallel --filter 'CollectionTaskTests|CollectionTaskHarnessTests'
xcrun swift test --no-parallel
```

Then record environment, commit, counts and output files as in [#24's record](../issue-24/validation.md).

## Criteria → tests

| Criterion | Tests | Result |
| --- | --- | --- |
| Idempotent creation at the top of Inbox by default or Today explicitly; exact nonblank single-line Unicode; CR/LF and Unicode line separators refused without flattening | `newTasksGoToTheTopOfInboxByDefaultOrTodayExplicitly`; `blankAndMultilineTitlesAreRefusedWithoutFlattening` × 12 (blank, ideographic space, LF, CR, CRLF, NEL, U+2028, U+2029, VT, FF, trailing LF) for create and edit; `creationIsIdempotentPerOperationAndPayload` (20 concurrent; title, placement and cross-kind reuse refused); `aLostAcknowledgementRetryReturnsTheTaskInItsCurrentState` | Not run |
| Title edit, move, complete, reopen, archive, restore per the table | `theLifecycleMatrixFollowsTheAgreedTable`; `titleEditsChangeContentTimeAndOrganizationDoesNot` | Not run |
| Exactly active unfinished tasks have placement and order (commands and schema); restore before edit/complete/reopen/move; no delete | Schema checks from #24; every test asserts placement/order per state; `archivedTasksMustBeRestoredBeforeAnyChange`; `completed` refusal for moving a completed task | Not run |
| Atomic top insertion, stable ties, overflow-safe renumbering; timestamps preserved by organization; revision, generation, no-op and receipt rules | `topInsertionRenumbersWhenKeysRunOutWithoutLosingAnything`; `satisfiedTaskCommandsAreNoOpsButStaleOnesFail`; `competingTitleEditAndArchiveCannotOverwriteEachOther` | Not run |
| Item/Inbox/Today/Completed/Archive/all reads and observations; title/text projection excluding archived/completed by default; Today survives midnight/DST | `everyCompletionAndArchiveCombinationAppearsInExactlyItsViews` (all four combinations, every view and eligibility setting, restart); `searchTextMergesNotesAndTasksByContentEditedTime`; `observationsFollowTaskTransitions`; `todayMembershipIgnoresMidnightDSTAndTimeZoneChanges` | Not run |
| Failed commands publish nothing; restart; harness | `failedTaskCommandsPublishNothing` (all seven commands); `organizeATaskAcrossFreshProcesses`; `killedCompletionIsAllOrNone` × {before-commit, after-commit} | Not run |

## Limitations

- Unverified: see Status.
- Time-zone change is argued, not simulated: the Store reads no calendar or time zone, and changing the process-global zone would race other parallel tests. Midnight and the 2026-03-08 US DST change are exercised through the injected clock.
- Process-crash (not power-loss) scope, as #24. Manual reorder is #27.
