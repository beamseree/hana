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

## Review and final regression result

The [two-axis review](review.md) reported one P3 Standards finding, resolved in `2f34bfb` by using `@concurrent` export/validation entry points; Spec reported zero actionable findings.

The isolated Store rollback/retry rerun passed. The first non-native run (98 tests) instead hit the existing DisplayPlacement deadline assertion: 1.060796084 seconds versus a 1-second threshold. No native windows were involved in that injected deadline test. These initial failures remain recorded; neither Store nor display-placement source was changed.

Final non-native regression command after the review fix:

```sh
HANA_EXECUTABLE="$PWD/build/Hana.app/Contents/MacOS/Hana" xcrun swift test --no-parallel --skip 'NativeEditingTests|MacInteractionTests|DestinationInteractionTests|ResultIconInteractionTests|SearchResponsivenessTests'
```

Result: **98 tests in 12 suites passed** in 14.278 seconds. Explicit serial test execution prevents unrelated concurrent test load from consuming the existing deadline margin. The test module used source `2f34bfb`; fixture subprocesses in this run used the previously built `42609f2` bundle. The final signed bundle and fixture recheck below distinguish that identity precisely. This is not a full-suite pass because the coordinated native exclusions remain unrun.

Final signed build from `2f34bfb` passed release compilation, Info.plist lint, ad-hoc signing and strict signature verification. Mach-O UUID: `1D9A38BC-32E2-3CB0-921D-FDEC01693E00`; SHA-256: `a5ed3653f2afb8df3b184f60115571c292826e4ff61698444cef8fa4a4a135b9`. Signed `CollectionExportHarnessTests` rerun passed (1 test, 0.650 s). The [content-free signed transcript](signed-fixture.jsonl) records full source commit IDs, binary/fixture paths, SQLite runtime/configuration, separate-process create/organize/read/export/validate events, final-code recheck and independent Python comparison preserving the earlier export. Runtime: linked SQLite 3.51.0, source ID `2025-06-12 13:14:41 f0ca7bba1c5e232e5d279fad6338121ab55af0c8c68c84cdfb18ba5114dcaapl`; WAL/FULL/fullfsync/checkpoint_fullfsync/foreign_keys verified by Store runtime report; read-only reader rejects checkpoint with code 8. This ticket preserves #24's Store/runtime safety design; it does not reassess vendor SQLite fix coverage.

The Standards reviewer rechecked `42609f2..2f34bfb` and confirmed zero unresolved findings. Final evidence-only commits do not change the tested code. Combined AC10 and excluded native testing remain outstanding in their stated scopes.
