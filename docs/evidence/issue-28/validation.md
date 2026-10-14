# Issue #28 validation

Date: 2026-10-14 (Asia/Bangkok). Review baseline: `210e9f34de86d751de6eb80a584cc41cde560ee3`. Worktree: `/Users/beamsereeyothin/.codex/worktrees/fe27/hana`; branch: `codex/issue-28-collection-export`.

## Scope and evidence boundaries

The pre-agreed seams are Collection Store and Collection Recovery. Tests use real temporary SQLite roots and production modules. The independent decoder shares no export DTO, decoding, hash or date-conversion implementation. Source/build acknowledgments, automated behavior and human-observed native focus are separate claims. No installation, normal app launch or personal collection access was performed.

The coordinator explicitly excluded native testing for this ticket because no testing slot was granted and native/app wiring is unchanged. Exclusions: `NativeEditingTests`, `MacInteractionTests`, `DestinationInteractionTests`, `ResultIconInteractionTests`, and opt-in `SearchResponsivenessTests`. A passing remaining suite is **non-native regression evidence**, not a full-suite/native-focus pass.

## Acceptance map

| Requirement | Automated evidence |
| --- | --- |
| One complete committed capture, including empty collection | `emptyCollectionPublishesACompleteVersionedPackage`; `independentReconstructionPreservesExactBytesAndEveryOrganizedView` |
| Exact Unicode/Markdown, duplicate/path-like titles, pins, every archive/completion state, order/times/revisions/identity | Unchanged `OrganizedCollection` fixture: 7 notes, 14 tasks; independent decoder reconstructs all records and six organized query views; direct byte comparisons for every Markdown file |
| Concurrent writes remain coherent | Paused export allows note edit, completion and reorder before publication; 20 racing exports match one of 33 actual committed states from edit/reorder/complete/reopen commands |
| Missing/tampered/unsupported/count/hash/domain/path/ID failures | `validatesTheCompletePackageAndRejectsCorruption`: 25 cases including valid, malformed UTF-8, duplicate IDs, bad derived title, future versions, symlinks, extra file and unpublished staging namespace |
| Failure-safe publication and prior copies | Five controlled failures: EIO, EROFS, ENOSPC, existing final destination, invalid staged package. Source and earlier export compare equal afterward; retry succeeds. Actual owner-unwritable directory produces EACCES. Source/default roots and aliases are refused |
| Fresh-process harness, reconstruction, no unsaved/internal content | `organizedCollectionSurvivesFreshProcessExportAndIndependentReconstruction`: organized Store closes; failed sentinel save rolls back in a subprocess; another process exports and another validates; independent decoder matches all original views; sentinel absent from source files, package and captured outputs |
| Bounded AC10 contribution | Creation/organization → fresh-process export → independent reconstruction covered here. Combined snapshot/disposable-reopen journey is coordinator-owned integration work once #28 and #29 are available |

## TDD and results

The implementation followed vertical red/green slices: absent Recovery API; empty package; organized reconstruction failing on missing data; missing validator; failure-safe publication API; fixture harness returning usage; and unpublished staging accepted before its rejection rule. Focused tests passed after each slice. Local detailed logs are under `build/coordination/` (ignored).

- Focused export run: 8 tests in 2 suites passed, including parameterized corruption and publication cases.
- Initial broader Collection run: 64 tests, one failure in existing `CollectionStoreTests.failedWritesRollBackCompletelyAndTheOperationCanBeRetried` (`alreadyOwned`). Export tests passed. Store is unchanged by this ticket; reported to the coordinator. Recheck and broader results are recorded below as they finish.

## Runtime/build identity and remaining checks

Host macOS 26.4.1 (25E253), arm64; Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, clang 2100.1.1.101). Package pins GRDB 7.11.1. Release build, signed fixture run and non-native regression results will be appended before handoff.

No actual disk-full, device/power-loss, hostile-filesystem or production replacement recovery experiment was run. Controlled errors establish bounded failure handling. Future editor flush behavior is a documented caller precondition, not a tested editor. The accepted eventual backup/restore scope and inherited native limitations remain outside this ticket.
