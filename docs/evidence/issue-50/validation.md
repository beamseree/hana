# Issue #50 — typing-pause file queries and a faster Spotlight adapter

Verified on 2026-10-14 on branch `claude/next-issues-6f54f5`, starting from `563291c`. Part of #47.

## Change

- **Typing gap.** Search times indexed-file queries with an injected clock. When no edit arrived within the typing gap, the file query starts at once. Otherwise it waits until the gap passes without another edit, then runs once with the latest text. A newer request stops the previous query. Application and retained results are never held by the gap. The gap is 50 ms (`Search.defaultTypingGap`); `--typing-gap-ms N` overrides it for validation runs.
- **Spotlight adapter.**
  - The exact, prefix and substring stages start together.
  - Notification batching is 20 ms.
  - The query has no sort descriptors. Removing them exposed that query values exist only for requested attributes, so the filename is now requested in `valueListAttributes`. Without that, every indexed result was silently dropped; the live tests caught it.
  - Hidden-item and package checks run only on shortlisted candidates. Their verdicts are cached per parent directory for the query's lifetime, and an excluded candidate frees its place.
  - A stage that has published nothing yet publishes after every 128-item chunk. Its first matches no longer wait for the whole result set. A stage that already has results still replaces them only once a pass completes, so a visible row is never removed mid-pass.
- **Hot-path costs found during validation** (details below):
  - `Search.eligible` rebuilt its private-folder paths on every call. They are now built once.
  - The adapter prepared each filename three times. It now checks the cheap path eligibility first and prepares each name once.
  - Ranking's final tie-break rebuilt each URL's path on every comparison. The path is now prepared once per candidate.

## Automated evidence

- Typing-gap tests (`SearchTypingGapTests`, test clock):
  - an edit after an idle gap starts the file query immediately;
  - edits within the gap start no query until it passes, then exactly one with the latest text, and the running query for the earlier text is stopped;
  - applications and retained results arrive while the file query waits.

  The existing stale-generation and cancellation tests still pass with the gap.
- Spotlight tests (`SpotlightStageTests`):
  - all three stages start before any finishes gathering (live);
  - a name match survives thousands of extension-only `pdf` matches in the shortlist (live);
  - hidden files and files in hidden folders stay excluded after shortlisting (live). The test waits until `mdfind` reports every fixture indexed, so the check is not vacuous;
  - packages exclude their contents (filesystem check, always run). On this OS Spotlight does not index files inside an `.rtfd` package, so the live index cannot exercise that rule.
- [Full suite](full-tests.txt): `xcrun swift test --no-parallel`, 180 tests in 25 suites passed; 11 environment-gated tests skipped.
- [Live-index run](live-index-tests.txt): every Search, ranking, exclusion, Spotlight and responsiveness test with `HANA_LIVE_INDEX`, `HANA_RANKING_FIXTURE`, `HANA_BOUNDED_FIXTURE`, `HANA_INDEXED_FIXTURE` and `HANA_PERFORMANCE_CHECK` set passed: 57 tests in 6 suites, none skipped. The input-queue probe's worst delay was 5.8 ms.

## Performance

Conditions:
- Installed release build with ad-hoc signing and diagnostics on, launched through `./scripts/run --diagnostics --validate-performance --typing-gap-ms N`.
- macOS 26.4.1 (25E253), Swift 6.3.3, two displays, Accessibility trust false, Full Disk Access granted to Hana (as recorded in #10).
- Query `Hana` against the existing indexed fixtures and the real index.
- Executable SHA-256 `5b0257374c34aea87dd6e9a7eee0bc5ada5d58d1a6fd3f19fdb6e3dc68debaf0`, built and installed copies identical.
- One complete uninterrupted run per gap. Summaries come from `scripts/validation/summarize-performance`, with nearest-rank p95.

The validation now:
- clears the query before each dismissal, because Search keeps the previous request's matching results across invocations. Without this, every warm sample after the first showed the previous sample's rows within about 6 ms, before any source responded ([labelled artifact](superseded/performance-gap-0-retained-artifact-summary.json)). This made the figures incomparable with #10;
- adds a rapid-typing phase: 10 samples typing `Hana` one character every 30 ms, faster than the gap. It measures the first file result after the last keystroke and scheduling excess during the phase.

| Warm measurement (ms) | #10 post-FDA baseline | Gap 0 ms | Gap 50 ms | Target |
| --- | --- | --- | --- | --- |
| First application result, median / p95 | 175.7 / 193.3 | 29.6 / 36.1 | 30.6 / 37.4 | median < 50 ✓ |
| First indexed-file result, median / p95 | 228.1 / 272.9 | 85.7 / 99.2 | 84.2 / 96.9 | median < 228 ✓ |
| Rapid typing: first file after last keystroke, median / p95 | — | 132.6 / 340.4 | 119.6 / 148.5 | — |
| Scheduling excess over 50 ms, whole run / rapid typing | 0 | 0 / 0 (max 47.6) | 0 / 0 (max 45.0) | none ✓ |

[Gap 0 summary](performance-gap-0-summary.json) · [gap 50 summary](performance-gap-50-summary.json) · raw [gap 0](performance-gap-0.jsonl) and [gap 50](performance-gap-50.jsonl).

**Chosen gap: 50 ms.** Single keystrokes after a pause behave the same at either value. During rapid typing, the 0 ms gap starts a file query per character; its tail is more than twice as long (p95 340 ms against 149 ms), because each superseded query still costs Spotlight and adapter work.

### Superseded first measurements

The first comparable runs, before the hot-path fixes, missed both targets: warm first application result 51–53 ms median, and warm first file result 432–443 ms median ([files](superseded/)). Per-stage timing in the installed app showed why. With Full Disk Access, the warm `Hana` prefix stage returns 319 results in its first notification, against 23 in the test process without it. The adapter published a stage only after processing every result, at about 0.9 ms per item. Release-build microbenchmarks attributed most of that to the three costs fixed above. The cold sample was faster only because Spotlight delivered small first batches.

## Limits

- One run per gap. Cold means process-cold or a fresh catalog, not a cold index. Results are observed through Mac Interaction at 2 ms polling, not screen paint.
- Scheduling excess samples a 5 ms heartbeat; it cannot attribute a pause to Search. Physical keystroke-to-display latency is not measured.
- Search's retention of previous results across dismissals is existing #49 behaviour, recorded here only because it affected measurement.

## Review

Separate standards and spec reviews found no hard violations and no incorrectly implemented requirement. Fixed after review:
- an observation stated as general fact in a test comment;
- the Alfred documentation link in the technical design;
- an abandoned waiting file task in one typing-gap test, which now also checks the held query starts once the gap passes;
- a reused variable name in the summarizer.

Left as is:
- The rapid-typing loop in the performance validation repeats the integrated loop's presentation and polling.
- No test holds one stage open to check that the source status stays loading. That status rule is unchanged code.
- The gap choice rests on one run per gap and 10 rapid-typing samples, so its p95 is effectively the maximum.

Stage filtering now uses `SearchName.fullNameTier`, which, like the removed `Search.matchTier`, matches the complete filename including its extension. Each stage keeps the same files as before.
