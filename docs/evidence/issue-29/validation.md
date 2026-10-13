# Issue #29 validation — Create and reopen basic validated collection snapshots

2026-10-13. Part of #22 (AC7; snapshot portions of AC8–AC10, and the combined AC10 journey). Builds on #28. Design: [technical design](../../technical-design.md#basic-snapshots--issue-29).

## Status: written without a compiler — not yet built or run

Written in a Linux cloud session with no Swift toolchain or macOS SDK. **Nothing below has been compiled or run**; every result is *Not run*. On the target Mac:

```sh
xcrun swift build
xcrun swift test --no-parallel --filter 'CollectionSnapshotTests|CollectionSnapshotHarnessTests'
xcrun swift test --no-parallel
```

## Criteria → tests

| Criterion | Tests | Result |
| --- | --- | --- |
| Manual creation, listing/inspection and status in Recovery via the Store's internal backup; online backup off the main actor; never a raw file copy | `aSnapshotOfAnUncheckpointedWALReopensWithEveryFact`; `CollectionStore.backup(to:in:)` uses `Database.backup(to:)` inside one pool read | Not run |
| Coherent capture point recorded; uncheckpointed WAL; controlled concurrent commands | WAL size > 0 before the snapshot in the first test; `snapshotsDuringConcurrentCommandsCaptureOneCommittedState` (6 snapshots racing 60 rounds; each copy satisfies the cross-item invariant; the last equals the final state); manifest `capture` and `latestUpdatedAt` | Not run |
| Staging closed and validated (schema, integrity, foreign keys, domain) with versioned UTC/identity/count/hash manifest before publication; separate from the active store; only valid copies usable | `aSnapshot…` (exact file set); `snapshotsAreSeparateFromTheLiveCollectionAndOwnerOnly`; `invalidSnapshotsAreRefusedAndListedAsUnusable` | Not run |
| Copy reopened in a new disposable Store without source WAL; all facts compared including pins, order and every completion/archive combination; sole snapshot never mutated | `aSnapshot…` (OrganizedCollection; snapshot bytes unchanged after reopen; live contents unchanged) | Not run |
| Corrupt/truncated/future snapshots, bad manifests and incomplete artifacts rejected; controlled failures preserve source and earlier copies; explicit retry; no automatic deletion | `invalidSnapshotsAreRefusedAndListedAsUnusable` × 13 (including a WAL-marked header); `failedSnapshotsPublishNothingAndPreserveSourceAndEarlierCopies` (ENOSPC, EIO at close, EDQUOT, EROFS, publication failure, a real `0500` directory; earlier copy byte-identical; retry succeeds); `anInterruptedSnapshotIsListedAsIncompleteNeverUsable` | Not run |
| Sentinel exclusion; harness create/list/inspect/reopen; ordinary backup evidence separate from crash/power-loss | `unsavedTextNeverReachesASnapshot` (with positive control); `theFoundationJourneyAcrossFreshProcesses` | Not run |
| No scheduling, retention, background retry, safety reversal, restore, generation pointer, migration or crash campaign | None added; `reopenSnapshotCopy` only creates a new disposable fixture root | Not run (review) |
| AC10 journey: create/organize → restart → export → snapshot → disposable reopen | `theBoundedFoundationJourneyAgreesEndToEnd` (in-process, full equality across Store, independent export decoder and reopened copy); `theFoundationJourneyAcrossFreshProcesses` (every step a fresh process) | Not run |

## AC10 handoff (#22)

| #22 criterion | Slice evidence |
| --- | --- |
| AC1 real foundation | [#24](../issue-24/validation.md) |
| AC2 committed persistence | #24; edit/organize persistence and kills in [#25](../issue-25/validation.md), [#26](../issue-26/validation.md), [#27](../issue-27/validation.md) |
| AC3 notes | [#25](../issue-25/validation.md) |
| AC4 tasks | [#26](../issue-26/validation.md) |
| AC5 ordering | [#27](../issue-27/validation.md) |
| AC6 full export | [#28](../issue-28/validation.md) |
| AC7 snapshots | this record |
| AC8 bounded failures | each slice's failure tests |
| AC9 no unsaved persistence | #24; export and snapshot sentinel tests |
| AC10 journey | the two journey tests above |

Only #24's rows have been run. #25–#29 must be built and run on the target Mac, with the source commit, environment and outputs recorded, before #22 can be called complete.

## Limitations

- Unverified: see Status.
- `Database.backup(to:)` is GRDB's public online-backup API as recalled from its documentation, not checked against the 7.11.1 sources in this session.
- Space and close failures are injected; one real read-only directory. No disk-full or power-loss campaign; snapshot publication durability across power loss is not claimed.
