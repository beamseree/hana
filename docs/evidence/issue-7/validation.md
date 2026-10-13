# Issue #7 — Search correctness

Parent: #2. Blocker #6 closed on 2026-10-13; merged PR #14 is ancestor `b6399e17bd60e6f27d6fd410dd36759900ecb341`. Work is confined to `codex/issue-7-search-correctness`. #8 was open at initial verification; final readiness must check again.

## Implemented behavior

Search compares canonical Unicode, case-folded and whitespace-normalized values, preserving Thai combining marks, punctuation and original input. Ordering is exact / phrase prefix / all-token substring, then extra comparison-name character count (closeness), successful-use sequence (recent first), frequency capped at 10, and standardized destination path. The strongest alias supplies match quality; catalog presentation is retained when a metadata alias matches. Usage belongs only to the Search instance and is recorded after a current native open acknowledgment.

Ranking retains 20 identities and yields/checks cancellation every 128 candidates; a second pass recovers presentation for retained identities only. Spotlight gathers strong tiers first and processes every available candidate in 128-item chunks, retaining at most 256 eligible unique candidates per tier. Exclusions/duplicates do not consume the shortlist. This bounds individual processing chunks and retained candidates, not total search latency or Spotlight's internal result storage. Broad searches can take longer and retain partial status at the cap. No icons are eagerly loaded (existing text rows are unchanged).

Mac Interaction retains selected identity through batches, invalidates disappearing selections, and captures the visible destination for Enter. Changing query now invalidates a pending open, allowing a new destination request while fencing obsolete completion/failure/activation. Native launch requests already issued cannot be recalled.

## Automated evidence

Agreed boundaries: Search query-to-batches behavior and Mac Interaction session/destination behavior. No ranking/selection test module was introduced. Existing tests cover generations, clearing, literal tokens, distinct installations and native destination revalidation. Added cases cover closeness/recency/stable ties, normalized whitespace with Thai marks and symbols, 12,002 candidates (hidden, weak, repeated, late exact/prefix), source failure/recovery, successful-only session usage, mixed navigation/removal, rapid reopen with batches/failure pending, and opening a new query while an old request is pending.

TDD failures captured before fixes:
- `closenessThenRecentSuccessfulUsePrecedeFrequencyWithinATier`: frequent long prefix incorrectly beat closer/recent results.
- `comparisonNormalizesWhitespaceAndCaseButPreservesThaiMarksAndLiteralSymbols`: equivalent comparison names received different tiers.
- `equalClosenessUsesStableIdentityRatherThanSourceOrDisplayOrder`: display name incorrectly preceded identity.
- `indexedLiteralExactSurvivesMoreThanTwoThousandBroadFalsePositives`: exact literal filename absent behind 2,100 conservative metadata matches; passed after chunked gathering (6.362 seconds in focused debug run).
- `newQueryCanOpenWhileAnObsoleteOpenIsStillPending`: old operation blocked the new selected destination.

The indexed regression creates 2,100 synthetic `[ 0000 Hana7 *].txt`-style files and exact `[Hana7*].txt` under `~/Hana Issue 7 Validation`, imports that directory, then runs Search with `HANA_BOUNDED_FIXTURE` set to the exact path. It is opt-in because it requires indexed filesystem fixtures. This terminal test proves the adapter regression, not app-specific permission coverage. It does not change privacy or Spotlight exclusion settings.

`tests.txt` records the full suite with the bounded indexed fixture enabled. `tdd.txt` records failing expectations and focused green results. Toolchain: Xcode 26.6 (17F113), Swift 6.3.3, macOS 26.4.1 (25E253), arm64.

## Interactive evidence

Pending at this commit. The opt-in `--validate-search-correctness --diagnostics` path demonstrates delayed exact ranking after navigation, removal requiring selection, failure/recovery, stale batches after dismissal/reopen, and real file/Calculator opening through the production Mac Interaction adapters. It returns to normal sources afterward. Synthetic display labels identify controlled data; destinations remain exact real URLs. Physical focus, typing, and full-screen behavior must be separately observed.

Native slot belongs to #7 first. User quit the existing Hana process before installation. No unfamiliar process was terminated and no permissions, system shortcuts, Spaces settings, or other checkout were modified. Record revision, installed executable SHA-256, signature CDHash, observed outcomes and slot release below before readiness.
