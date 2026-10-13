# Issue #6 — mixed indexed filename Search

Implements [#6](https://github.com/beamseree/hana-searchbar/issues/6), part of [#2](https://github.com/beamseree/hana-searchbar/issues/2). Broader location/permission/performance coverage remains #9. No persistence, content search, capture, organizer, folder-selection setup, privacy/indexing changes, or prototype edits.

## Baseline and identity

Blocker #5 was CLOSED; merged PR #13 is commit `d57ea7e6ade47202ce406653420061f5c0d4575d`. This worktree initially stopped at #4 and was moved to that commit when creating `codex/issue-6-mixed-file-search`. Its ancestry check passed. That commit is the user-confirmed review base.

Environment rechecked: macOS 26.4.1 (25E253), Apple Silicon, Xcode 26.6 (17F113). Build/install uses `scripts/run`, `com.beamseree.hana`, `~/Applications/Hana.app`, ad-hoc signing without entitlements. Strict verification passed; no claim of distribution readiness or permission continuity.

## Implementation contract

Search merges independently consumed catalog and metadata snapshots. Each source has loading, ready, partial or failed status. A coalescing signal and one latest snapshot per source bound pending work; the UI receives at most 20 rows after the existing 100 ms debounce. Failures retain available results; zero results do not diagnose permission denial or prove absence.

The internal Spotlight adapter owns NSMetadataQuery on the main run loop with `.main` notification delivery. Startup, bounded attribute copies, disable/enable updates, live notifications, stop and observer removal all occur there. Only immutable Sendable name/URL/type values go to detached eligibility work; no NSMetadataItem crosses actors. Per-stage revisions reject superseded processing. Cancellation stops all three queries and cancels detached work. Exact then prefix then all-token broad queries gather separately; each stage inspects at most 2,048 metadata entries and retains at most 256 eligible candidates. Exclusions and literal tier checks precede the eligible limit. Hitting a processing/candidate budget reports partial coverage, not completion of the entire index.

Comparison preserves Thai marks and uses canonical normalization/case folding without changing the editor. Predicate syntax/keys are constant and values bound. On this OS, compound punctuation such as `[*]` was not returned by a naive bound CONTAINS predicate even though separate symbols matched. Punctuation queries therefore gather conservative bound fragments with prefix/suffix constraints for strong tiers, then verify the complete literal name/all tokens before candidate limits. Metadata candidates for applications include `.app` filenames; catalog aliases and exact installation identities remain intact. No content or parent-path matching.

Hidden path components/flags, actual `.Trash`/`.Trashes`, package/bundle ancestors and Hana's private support/cache/log/preferences locations are excluded. An ordinary visible folder named `Trash` stays eligible. Visible files/folders have no document whitelist. URL fallback identity deduplicates catalog/metadata applications without merging distinct installation URLs.

Mac Interaction retains the selected identity through late batches. Return captures that destination, revalidates file existence/readability off the input actor, and uses native default-handler opening with activation disabled. Current invocation/query guards fence dismissal and exact returned-instance activation. Reported failure retains query/context. An already-issued OS open cannot be recalled; a third-party app can independently activate itself. Acknowledgment is not document-display or physical-focus proof.

## Apple primary API verification

Checked current documentation and the installed SDK during implementation:

- [Query startup](https://developer.apple.com/documentation/foundation/nsmetadataquery/start()) requires the main thread or configured operation queue; false reports a failed start.
- [Operation queue](https://developer.apple.com/documentation/foundation/nsmetadataquery/operationqueue) controls query notifications. [Apple's metadata guide](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/SpotlightQuery/Concepts/QueryingMetadata.html) documents gathering/live updates, indexed result access, and disabling/re-enabling updates while reading.
- [Indexed local scope](https://developer.apple.com/documentation/foundation/nsmetadataqueryindexedlocalcomputerscope) is documented to search indexed mounted local volumes/home. A controlled terminal probe on this host returned zero for five queries with that constant, but found the known indexed fixture with [local-computer scope](https://developer.apple.com/documentation/foundation/nsmetadataquerylocalcomputerscope). The implementation uses the latter NSMetadataQuery scope, still with filename metadata and no manual disk crawl. This is a concrete deviation from the technical-design symbol recommendation, not an inference about permission or complete coverage.
- [Native URL opening](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:configuration:completionhandler:)) returns a running application or error asynchronously. The default handler was independently resolved as TextEdit for the synthetic `.txt` fixture. This does not establish physical focus.

## Automated evidence

Agreed seams: Search behavior and Mac Interaction. Red-to-green slices added independent source delivery/status, literal mixed filtering/deduplication, file-opening failure and ordinary folder eligibility. Cancellation tests observe underlying source termination as well as stale-batch rejection. Controlled delayed/failed file sources, stable/vanished selection, deleted-file native revalidation, and old file acknowledgments are covered. Existing application matching, usage within tiers, catalog refresh and exact-installation behavior remain covered.

An opt-in live Search test uses `HANA_INDEXED_FIXTURE` and checks single-word, full literal, reversed multiword, Thai and `[*]` cases. It is skipped by default because OS indexing is external state, not a deterministic unit-test assumption. A first live failure caught the punctuation translation issue. A signed native run also exposed NSMetadataQuery's rejection of a one-child compound predicate; single-token predicates now avoid that form. Those findings were corrected before acceptance.

## Signed native evidence — 2026-10-13

Synthetic fixture: `~/Hana Mixed Search Validation/TextEdit Hana [*] บันทึก.txt`, marker `HANA-6-20261013`. Create idempotently with `scripts/validation/install-file-search-fixtures`; modified fixtures are never overwritten. Wait for ordinary indexing. No `mdimport`, indexing or privacy changes were used.

Run `scripts/run --diagnostics --validate-mixed-search --validation-file-delay` after quitting Hana. The opt-in validation harness calls the production Mac Interaction interface, waits for both the exact fixture URL and an application result, chooses that identity, then opens it. The delay is five seconds at the internal file-source boundary; normal launches have no artificial delay.

At 14:33 ICT:

1. **Discovery:** a ready TextEdit application result was available around 964 ms after query start, while file status was loading. File gathering deliberately waited five seconds. A mixed batch containing the exact fixture arrived around 5,283 ms; `validation.mixed-discovery` records both booleans.
2. **Request acknowledgment:** the harness selected the exact fixture, `launch.request` recorded File, followed by `launch.acknowledged`, destination dismissal, and an accepted activation request. The origin was Finder. The acknowledgment still reported Finder as workspace-frontmost and is not presented as focus proof.
3. **Observed destination:** a separate TextEdit accessibility observation showed the exact percent-encoded home-folder fixture URL, document title, complete three-line fixture text and `HANA-6-20261013` marker. Its text view was the reported focused element. This establishes the actual document display; physical keyboard delivery still needs human observation.

Earlier, a Documents copy was indexed/discovered in terminal tests but not returned in the signed-app query. A home-folder copy appeared through the still-running query after creation, giving live-update evidence. No permission-denial diagnosis is inferred; broader protected-location investigation belongs to #9. An initial automated row-click/Return produced acknowledgment without immediately observed document display; the explicit-identity harness above established the destination independently.

Initial timings are small instrumented samples, not final p95 or typing-stall guarantees. The deliberately delayed cold-catalog sample does not meet the final warm engineering budget, and is not represented as one.

## Physical acceptance

Pending final-build human checks: normal/full-screen invocation and immediate typing; mixed keyboard selection/default opening with destination typing; Escape/outside-click return; reinvocation/rapid reopening; English/Thai paste/selection/undo; working windows open/minimized with no unexpected raising or Space jump. The existing window machinery is unchanged, but previous #5 observations alone do not establish #6 integration. Candidate IME remains explicitly deferred.

## Review correction

Both independent review axes found the same pre-match deduplication bug: a catalog alias without `.app` could hide the metadata filename match. The failing regression now passes after merging all names by destination before scoring, retaining catalog display names. A stronger metadata alias also improves its tier without replacing presentation. See [two-axis review](review.md).


## Final automated/build checks

After the review correction, all **28 tests** passed, including the opt-in live fixture test, in the complete suite. See [test output](tests.txt). Release build/plist/strict signature checks passed; [build output](build.txt). The installed binary for the physical request has CDHash `5dac79e8e5e56e30f5d5e5c4453c5c81ed2f9406`, no TeamIdentifier and no entitlements. Both reviewers rechecked the correction with zero remaining actionable findings in each axis.
