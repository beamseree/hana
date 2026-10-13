# Issue #24 validation — Save a note durably through the Collection Store

2026-10-13. Part of #22 (AC1, AC2, AC8, AC9 and the foundation part of AC10). Design and decisions: [technical design](../../technical-design.md#collection-store-foundation--issue-24).

## Environment and identity

macOS 26.4.1 (25E253), arm64, Apple Swift 6.3.3, GRDB.swift 7.11.1 (`b83108d`, MIT). The signed release app (`./scripts/build`, ad-hoc, `com.beamseree.hana`) links `/usr/lib/libsqlite3.dylib` 382.0.0 and reports SQLite 3.51.0, source ID `2025-06-12 13:14:41 f0ca7bba…aapl`. [Runtime report and build identity](runtime.txt), [build](build.txt).

## Results

| Criterion | Evidence | Result |
| --- | --- | --- |
| Pinned GRDB; dependency/license; linked SQLite identity; WAL-reset fix assessment; effective WAL/FULL/full-sync/foreign keys; checkpoint behavior | `Package.resolved`; [runtime.txt](runtime.txt) from the signed release binary; `linkedRuntimeUsesDurableSettingsAndOnlyTheWriterCanWriteOrCheckpoint` | **Partially met.** Identity and settings verified on the actual runtime. Vendor fix coverage is **not established**; per Beam's 2026-10-13 decision the documented trigger is excluded structurally (single writer, read-only readers that cannot checkpoint, exclusive owner lock). |
| Initialize only a genuinely new marked root; same-schema reopen with explicit schema history; preserve missing/corrupt/unsupported/open-failure artifacts | `savedNoteSurvivesReopenWithExactBodyAndDerivedTitle`; `refusedExistingStoresArePreservedByteForByte` × 7 (missing database with orphaned WAL, empty `Collection`, not a database, truncated, newer, older, foreign); `fixtureRootsMustBeNewMarkedAndOutsideTheLiveRoot` | Met. Durable files stay byte-identical; SQLite's transient `-shm` index may be rebuilt but is never removed. |
| Private Application Support storage; owner-only access; lifetime guard; fixture refuses live root, descendants and aliases; process death releases ownership | `storageIsOwnerOnlyWhileLiveAndRefusedWhenWidened`; `aSecondOwnerIsRefusedUntilTheFirstCloses`; `processDeathReleasesOwnership`; `fixtureRootsMustBeNewMarkedAndOutsideTheLiveRoot`; `harnessRefusesTheLiveRootWithoutCreatingIt` | Met. The real live root was not created by any test. |
| Typed perform/read/observe; stable IDs, exact body, derived title, timestamps/revisions, immutable committed values; coherent, converging observations without rollback/partial state | `savedNoteSurvivesReopenWithExactBodyAndDerivedTitle` (Thai, decomposed accents, emoji, CRLF, U+2028, NUL, trailing spaces, byte-compared); `observationsStartCoherentlyConvergeOnCommitsAndNeverShowRolledBackWork` | Met. |
| Atomic operation UUID + payload identity + receipt; identical concurrent/lost-ack/fresh-process retries return one item; mismatched reuse fails; generation rotates; stale work rejected before receipt lookup; obsolete observations invalidated | `identicalCreationRetriesReturnOneNoteAndMismatchedReuseFails` (20 concurrent submissions; canonically equal but byte-different payload refused); `lostAcknowledgementRetryAfterRestartReturnsTheCommittedNote`; `createReadObserveAndRetryAcrossFreshProcesses`; observation test (`.closed`, `.staleGeneration`) | Met. |
| Fixture harness create/read/observe/restart; real SQLite rollback, targeted write failure and before/after-commit subprocess kills with idempotent retry | `createReadObserveAndRetryAcrossFreshProcesses`; `killedCreationIsAllOrNoneAndRetriesIdempotently` × {before-commit, after-commit} (SIGKILL); `failedWritesRollBackCompletelyAndTheOperationCanBeRetried` (injected failure and a real SQLite CHECK violation, code 19) | Met for normal restart and process crash. **Not** power-loss evidence. |
| Unsaved/failed buffers memory-only; sentinel absent from database/sidecars and captured diagnostics | `unsavedSentinelNeverReachesStorageOrDiagnostics`: failed save in a subprocess, a process killed mid-transaction, an in-process failed write, a stale-generation submission and a never-submitted buffer, scanned in the database, WAL, `-shm`, fixture marker and all captured harness stdout/stderr, both while the WAL is live and after restart. A committed control string is found by the same scan. | Met. |

## Test runs

- Full deterministic suite, `xcrun swift test --no-parallel`: 64 tests in 9 suites passed (49 existing + 15 new), 6.7 s. [Output](full-tests.txt).
- Harness suite against the signed release binary (`HANA_EXECUTABLE=build/Hana.app/Contents/MacOS/Hana`): 5 tests passed. [Output](signed-harness-tests.txt).
- A default parallel `swift test` run hung in the existing `NativeEditingTests.lateResultsPreserveEditorSelectionUndoAndInputPosition` (spinning in `CatalogFeed.send`), consistent with the [#10 record](../issue-10/parallel-suite-invalid.txt) that parallel runs are invalid for this suite. It was terminated; no new test was involved in the sampled stacks.

## Limitations

- WAL-reset fix coverage for Apple's SQLite build is not established (see above). Other software opening the database file outside Hana is not excluded.
- Subprocess SIGKILL and rollback tests establish process-crash/restart behavior, not power-loss or torn-write durability. No disk-full campaign was run.
- No production launch path opens the live root yet; no capture UI, editor, export or snapshot exists. Schema version 1 has no upgrade path.
- Unchanged native/environmental limitations from #2/#10 (physical timing, IME candidates, ad-hoc signing continuity, proposed ADR 0005) are not re-evaluated here.
