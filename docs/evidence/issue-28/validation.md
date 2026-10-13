# Issue #28 validation — Export and reconstruct the complete collection

2026-10-13. Part of #22 (AC6; export portions of AC8–AC10). Builds on #27. Design: [technical design](../../technical-design.md#full-export--issue-28).

## Status: written without a compiler — not yet built or run

Written in a Linux cloud session with no Swift toolchain or macOS SDK. **Nothing below has been compiled or run**; every result is *Not run*. On the target Mac:

```sh
xcrun swift build
xcrun swift test --no-parallel --filter 'CollectionExportTests|CollectionExportHarnessTests'
xcrun swift test --no-parallel
```

## Criteria → tests

| Criterion | Tests | Result |
| --- | --- | --- |
| Full export from one coherent committed snapshot while writes continue; identity, provenance, every fact, counts and hashes | `exportReconstructsEveryDomainFactAndExactNoteBytes`; `exportsDuringWritesDescribeOneCommittedState` (8 exports racing 60 create/edit rounds; each package satisfies the cross-item invariant a torn read would break) | Not run |
| Exact UTF-8 notes under UUID names; versioned manifest and task JSON with pins, completion/archive, placement/order, times and revisions; validated paths/IDs; no title-derived paths | `exportReconstructs…` (OrganizedCollection: `../../etc/passwd`, `CON`, punctuation, dot-first, duplicate titles, Thai/NUL/U+2028/CRLF bodies); `tamperedOrUnsupportedPackagesAreRefused` (path traversal) | Not run |
| Staged on the destination volume, validated, published under a new name; no overwrite; no live-store writes; failed/partial outputs never reported complete | `laterExportsNeverOverwriteEarlierOnes`; `failedExportsPublishNothingAndPreserveEarlierOnes` (inside root/`Collection` refused); destination listing checks in every test | Not run |
| Independent decoder compares all canonical values and exact note bytes; empty, Unicode, duplicate/unsafe titles, pins, order, every completion/archive combination | `IndependentExportDecoder` (JSONSerialization only, no shared exporter types); `anEmptyCollectionExportsAndReadsBack`; `exportReconstructs…` | Not run |
| Missing/tampered files, unsupported versions and count/hash/domain mismatches rejected | `tamperedOrUnsupportedPackagesAreRefused` × 12 (missing note, changed bytes, extra file, symlinked note, format version 2, wrong format, count, `..` path, completed task with placement, title mismatch, malformed JSON, invalid UTF-8) | Not run |
| Bounded write/readonly/space/publication failures preserve source and earlier exports | `failedExportsPublishNothingAndPreserveEarlierOnes`: injected ENOSPC, EDQUOT, EIO and EROFS writes, publication failure, a real `0500` destination, missing destination; earlier package byte-identical; store contents unchanged | Not run |
| Unsaved sentinels, receipts and external references excluded; harness evidence | `unsavedTextAndCreationReceiptsAreNeverExported` (failed edit and create carrying a sentinel; operation UUIDs absent; positive control); `exportAndVerifyAcrossFreshProcesses` | Not run |

## Limitations

- Unverified: see Status.
- Disk-full and read-only failures are injected `errno`s, plus one real read-only directory; no real full-disk campaign. Publication uses `renamex_np(RENAME_EXCL)` within the destination directory; directory durability across power loss is not claimed.
- Flush-before-export is a documented caller contract (no editor exists yet).
- The combined AC10 journey is assembled with #29.
