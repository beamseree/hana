# Issue #27 validation — Manually reorder Inbox and Today safely

2026-10-13. Part of #22 (AC5; ordering portions of AC2, AC8 and AC10). Builds on #26. Design: [technical design](../../technical-design.md#manual-order--issue-27).

## Status: written without a compiler — not yet built or run

Written in a Linux cloud session with no Swift toolchain or macOS SDK. **Nothing below has been compiled or run**; every result is *Not run*. On the target Mac:

```sh
xcrun swift build
xcrun swift test --no-parallel --filter 'CollectionTaskOrderTests|CollectionTaskOrderHarnessTests'
xcrun swift test --no-parallel
```

## Criteria → tests

| Criterion | Tests | Result |
| --- | --- | --- |
| Typed reorder in Store and harness; independent Inbox/Today keys; Completed/Archive keep timestamp/ID order | `reorderMovesOneTaskAndPersistsAcrossRestart` (top, middle, bottom; Today untouched; restart); `reorderAcrossFreshProcessesAndRejectAStaleOrder`; Completed/Archive ordering from #26 | Not run |
| List preconditions checked at execution; obsolete reorder rejected after insert/move/complete/archive/reorder | `obsoleteOrdersAreRejectedAfterEveryKindOfConcurrentListChange` (each change, then the stale reorder fails and changes nothing); `racingReordersFromTheSameViewCommitExactlyOnce` (10 concurrent rounds); `theCurrentPositionIsANoOpAndInvalidRequestsChangeNothing` (wrong list, missing task, stale revision, completed, archived, out-of-range index) | Not run |
| Reorder and renumbering commit together; stable ties; overflow; coherent revisions/observations; nothing lost, duplicated or moved to the other list | `adjacentKeysRenumberTheListInTheSameTransaction`; `extremeKeysAtEitherEndRenumberInsteadOfOverflowing` × {top, bottom} (keys `Int64.min`/`Int64.max`); `midpointsBetweenExtremeKeysDoNotOverflow`; `aFailedReorderRollsBackRenumberingToo`; `observationsReachTheReorderedList` | Not run |
| Interaction with top insertion, move, reopen and restore; unchanged creation/content-edited times; no-op | `reorderInteractsWithInsertionMoveReopenAndRestore`; time assertions in `reorderMovesOneTask…`; no-op in `theCurrentPosition…` | Not run |
| Concurrent/restart tests, rollback, persisted ordered queries; organization fixtures for export and snapshots | The tests above; `OrganizedCollection` (test support) and `theOrganizedFixtureSurvivesRestart` | Not run |

## Limitations

- Unverified: see Status.
- Process-crash (not power-loss) scope, as #24.
