# Issue #7 — Search correctness

Parent: #2. Blocker #6 closed on 2026-10-13; merged PR #14 is ancestor `b6399e17bd60e6f27d6fd410dd36759900ecb341`. Work is confined to `codex/issue-7-search-correctness`. #8 was open at initial verification; final readiness must check again.

## Implemented behavior

Search compares canonical Unicode, case-folded and whitespace-normalized values, preserving Thai combining marks, punctuation and original input. Ordering is exact / phrase prefix / all-token substring, then extra comparison-name character count (closeness), successful-use sequence (recent first), frequency capped at 10, and standardized destination path. The strongest alias supplies match quality; catalog presentation is retained when a metadata alias matches. Usage belongs only to the Search instance and is recorded after a current native open acknowledgment.

Ranking retains 20 identities and yields/checks cancellation every 128 candidates; a second pass recovers presentation for retained identities only. Spotlight gathers strong tiers first and processes every available candidate in 128-item chunks, retaining at most 256 eligible unique candidates per tier using the same usage snapshot. Native updates are suspended only during each bounded metadata copy; live changes cancel obsolete replacement scans. A replacement preserves the previous complete results until the new snapshot is complete, avoiding transient selection loss. Exclusions/duplicates do not consume the shortlist. This bounds individual processing chunks and retained candidates, not total search latency or Spotlight's internal result storage. Broad searches can take longer and retain partial status at the cap. No icons are eagerly loaded (existing text rows are unchanged).

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

The opt-in `--validate-search-correctness --diagnostics` path demonstrates delayed exact ranking after navigation, removal requiring selection, failure/recovery, stale batches after dismissal/reopen, and real file/Calculator opening through the production Mac Interaction adapters. Quit and relaunch without that flag for physical checks with normal sources, within the same coordinated slot. Synthetic display labels identify controlled data; destinations remain exact real URLs. Physical focus, typing, and full-screen behavior were separately confirmed by Beam, as recorded below.

Native slot belongs to #7 first. User quit the existing Hana process before installation. No unfamiliar process was terminated and no permissions, system shortcuts, Spaces settings, or other checkout were modified. The tested identity and observations follow.

## Review corrections

The two-axis review found one Standards issue (updates suspended across awaited scanning) and two Spec issues (replacement prefixes could temporarily remove valid selections; usage-free adapter truncation could discard a usage winner). Corrections restrict suspension to synchronous copies, replace complete snapshots atomically, and pass the query's session usage into adapter compaction.

The opt-in 300-file equal-name fixture reproduced the usage-cap failure before correction and passed afterward. The adapter replacement regression passed both before and after; it is coverage, not claimed red/green reproduction of the scheduling-sensitive selection finding. The corrected code no longer publishes incomplete replacement prefixes.

Reproduce fixtures with `./scripts/validation/install-search-correctness-fixtures`, then `HANA_BOUNDED_FIXTURE="$HOME/Hana Issue 7 Validation/[Hana7*].txt" xcrun swift test --scratch-path .build`. The live metadata tests require a logged-in macOS session and indexed fixtures; their absence is an explicit skip.

## Installed build and native outcome — 2026-10-13

- Exact tested source revision: `d6aec50351f1aae634096186bcd294d566b9e0a4`. Later commits contain evidence only.
- Worktree-local outputs: `.build/` and `build/Hana.app`; install: `~/Applications/Hana.app`, bundle `com.beamseree.hana`, ad-hoc signed. Strict signature verification passed; no entitlements or signing/permission changes were introduced. Full details: `installed-build.txt`.
- Installed executable SHA-256: `d01424c0497cc0491a6e26fb08e4e483fd44ae7d1bdf4a2a7ea86cdf8d2b1bc8`.
- CDHash: `66d45e99b417f9f9fe7e08f1a6072abd44a84e89`.
- Initial 15:48 Bangkok run was interrupted by physical input changing the controlled query. It is not a pass. After Beam confirmed a hands-off replay, the same installed build completed the controlled sequence at 15:49–15:50.
- Runtime trace: `validation7.late-top.selectionPreserved=true`; removal `requiresSelection=true`; reopen `freshSession=true`, `resultsRetained=true`; real file and real application requests both acknowledged; `validation7.complete` recorded. This demonstrates controlled mixed batches in the running bar through production interfaces.
- UI observation: Calculator's real window was present, and TextEdit displayed the exact `~/Hana Issue 7 Validation/Hana7 Note.txt` document and its synthetic content. Reading these windows is not itself proof of focus transfer; that came from the physical confirmation below.
- Same build relaunched without the validation flag for normal indexed sources. Beam answered **“All five checks passed”** to: (1) physical Option+Space, `Hana7 Note`, arrow/Enter opening, and typing in TextEdit without a click; (2) exact `[Hana7*].txt` found; (3) rapid type/clear/Escape/reopen with empty fresh bar and no unintended opening; (4) full-screen invocation/type/Escape and outside-click typing without unwanted focus/Space changes; (5) English/Thai editing and paste/select/undo during results.
- Final Quit via Hana's menu at 15:53 Bangkok. Runtime `shutdown` follows `MacInteraction.stop()` unregistering the shortcut. `pgrep -x Hana` confirmed no remaining process. **#7 native testing slot released.** No later installation or interactive launch was performed.

The complete full suite passed **40 tests** (13.928 seconds in the final run), including three opt-in live-indexed regressions. The separate earlier punctuation fixture test remained skipped unless `HANA_INDEXED_FIXTURE` is supplied; punctuation is otherwise covered by controlled and bounded live-indexed tests plus the physical exact search. Native acceptance here is scoped to #7; this does not claim completion of all parent #2 coverage, permissions, display, performance, or working-window matrices. Candidate IME compatibility remains deferred per the parent. Broader locations, genuine permission denial/revocation, all-minimized working windows and display reconnection were not revalidated for this Search-only change.

## Final readiness check

After native slot release, fetched `origin` and checked #8 and PR #15 (`codex/issue-8-display-and-editing`): both remain open, with `mergedAt=null`. `origin/main` remains the #6 merge `b6399e1`; no #8 integration was applicable before this PR was marked ready. No other checkout was modified. The independent reviews have zero unresolved implementation findings; this ticket's core acceptance has automated, runtime and human evidence. No merge was performed.
