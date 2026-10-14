# Issue #54 — failure status and default shortlist coverage

Implemented on `codex/issue-54-search-regressions`, starting at
`f0e63bf92c3d96ffc162a6f4166dc43db612adb3`. Verified 2026-10-14 with Xcode
26.6 (17F113), Swift 6.3.3, macOS 26.4.1 (25E253), arm64.

## Change

Mac Interaction records the request generation that supplied its displayed
snapshot. A source failure describes available results only when the snapshot
belongs to the current request and contains rows. Retained previous-query rows
and empty results get failure-and-retry wording without a results claim. This
does not change row replacement, selection, opening, ranking or source timing.

The default ranking suite now sends 603 synthetic candidates through the same
`Search.compactCandidates` boundary used by Spotlight: 300 extension-only
matches, 300 mid-word matches, then word-start, prefix and exact matches in
reverse expected order. Repeated 128-item chunks fill the 256-item shortlist
before the strong matches arrive. Assertions check the cap, all three strong
matches in exact/prefix/word-start order, and agreement with visible Search's
20 results. The existing environment-gated live-index ranking test is unchanged.

## Automated verification

- The retained-row regression failed on the original status wording, then
  passed after the generation check. It also verifies the available-results
  wording once a fresh batch replaces those rows.
- Additional parameterized Mac Interaction coverage checks failure from either
  source after fresh rows, a subsequent request retaining those rows, and
  terminal empty results.
- `xcrun swift test --filter SearchRankingTests`: 14 tests passed, including
  the new fixture regression; the opt-in live-index ranking test was skipped.
- The broader `--filter MacInteractionTests` run failed two polling assertions
  in the existing `editingDuringAFinishedShrinkHoldsTheCurrentHeightWhileLoading`
  test while multiple suites ran concurrently. The new tests passed. A serial
  focused recheck of that resize test and the new parameterized test passed
  (2 tests, 0.531 seconds). No timeout or assertion was weakened.
- `xcrun swift build`: passed.
- Final `xcrun swift test --no-parallel`: **174 tests in 23 suites passed** in
  25.865 seconds, including the resize test. Eight environment-gated live-index
  checks were skipped. No fixture environment flag was set for this run.
- `git diff --check`: passed.

Debug executable identities for the final suite:

| Artifact | SHA-256 |
| --- | --- |
| `.build/debug/Hana` | `82936d8949674207c418463fee248030492c09b817dc1b671d07426b06fe403f` |
| `.build/debug/HanaPackageTests.xctest/Contents/MacOS/HanaPackageTests` | `108ea6795b9e48814ebd4f0a9a5dce9efe3d8ec584f14e6101a75c44b9c19bed` |

## Standards

Independent read-only review found no actionable findings. The displayed
generation remains private to Mac Interaction, follows request identity, and
resets with the rows. Tests use existing behavior boundaries without AppKit-call
mocks or a test-only production interface. No change-worthy baseline smell was
identified; every displayed-snapshot assignment updates its generation.

## Spec

Independent read-only review found no missing requirements, scope creep or
incorrect implementation. Both status cases retain retry guidance. The default
603-candidate test exercises the production adapter's compaction function under
the actual cap and verifies visible Search ordering. The gated test remains.

Review totals: Standards 0 findings; Spec 0 findings.

## Evidence limits

Beam explicitly handed over the native testing slot; it was released after the
final suite. AppKit fixtures presented real panels and asserted programmatic
state. No app was installed or normally launched, and no physical keyboard-focus,
live-index coverage or perceived animation claim is made. This record describes
the source and test binaries above, not the separately installed Hana build.
