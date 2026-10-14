# Issue #48 — Search matching and ranking

Implemented on `codex/issue-48-search-ranking`, based on `680bb1e1c146eadc172ff03e5d31fc4fc935818d`. Scope is matching, ordering, cached name preparation and the existing shared Spotlight shortlist. Delivery timing, card behavior, selection and opening are unchanged.

## Automated verification — 2026-10-14

Environment: Xcode 26.6 (17F113), Swift 6.3.3, macOS 26.4.1 (25E253), arm64.

- `swift build` passed. Focused test builds also typechecked the final enum refinement.
- Search's request-to-batches tests verify word starts versus substrings, camel-case boundaries, Thai segmentation and fallback, reordered query words, full and stripped filenames, declared versus unrecognized extensions, kind priority, closeness, word order, session usage, stable identity and application aliases. Existing eligibility, literal punctuation, normalization, deduplication and limit tests pass.
- TDD failures were observed before implementing word-start ranking, extension/kind priority, word-order precedence, bundle-name aliases and extension-stripped closeness for complete-filename queries.
- The focused Search suites passed **33 tests**, including the live Spotlight shortlist regression.
- The final full run, `HANA_RANKING_FIXTURE="$HOME/Hana Issue 48 Validation" swift test --no-parallel`, passed **143 tests in 22 suites** in 21.924 seconds. Unconfigured historical live-index and performance gates remain skipped.
- The earlier parallel full run hit two existing wall-clock limits: `replacingOrClearingAQueryCancelsFilesAndRejectsTheirLateSnapshots` exceeded the shared 3-second polling deadline, and `failedOrUnresponsiveAccessibilityUsesCapturedPointer` took 1.317 seconds against its 1-second ceiling. Both passed together in isolation (0.014 and 0.065 seconds) and in the serial full run. Their assertions were not weakened. The parallel full run is not claimed as passing.

## Spotlight shortlist

`scripts/validation/install-search-ranking-fixtures` creates 603 disposable synthetic filenames under `~/Hana Issue 48 Validation`: 300 extension-only `.aifc` matches, 300 mid-word `xaifc` matches, and exact, prefix and word-start matches. AIFC is a system-declared extension; the files contain only synthetic text. `mdfind` confirmed all 603 names were indexed before final verification.

The environment-gated test drives the production Spotlight adapter through Search and checks that `aifc.txt`, `aifc-guide.txt` and the alphabetically late `zzzz aifc best.txt` survive the 256-candidate shortlist in that order, within the 20-result visible limit. It passed in both the focused and full runs. This is terminal-process index evidence, not installed-app permission or keyboard-focus evidence.

Reproduce by running the fixture script, allowing Spotlight to index the names, then setting `HANA_RANKING_FIXTURE` as above. An initial AIFF fixture was replaced because this Mac has more than 20 unrelated, legitimately stronger AIFF prefix matches; immediate querying before index propagation also missed fresh files. Neither initial run is reported as a ranking pass. The final AIFC regression retains the same candidate-cap pressure without that visible-limit collision.

## Review and boundaries

Independent Standards and Spec reviews found no remaining findings. The Standards review's non-blocking suggestion to name match tiers was implemented with an ordered `SearchName.Tier` enum and rechecked. The Spec review confirmed #48's comparator order, cached names, extension rules, shared shortlist and unchanged delivery/UI scope.

No Hana installation, normal app launch, privacy-setting change or physical focus validation was performed for this ranking-only ticket. No sibling ticket, issue closure or merge was performed.
