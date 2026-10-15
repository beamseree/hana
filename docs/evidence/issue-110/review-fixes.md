# Issue #110 review repairs — 2026-10-15

Candidate reviewed: `4eec8ef00947aeccefcc37ce12c338d4ef6b21eb`.
Repaired source and regression tests: `b1e9cfd16b22962edcc6c87b77c8c039b6cc8916` (initial repairs `8e78dd3eb6783c2264889a6efb64a36e12c916cf`, followed by saved-confirmation end-status correction).
The source commit includes integration `361f0ccc9af331800d734a6dd663d00183a7766a` and the full #114 candidate. Both integration and candidate branch merges reported already up to date before the source commit.

## Standards findings

- **P2, title preparation:** CollectionTitleSource now awaits a private explicit `@concurrent nonisolated` preparation function. All SearchName normalization and tokenization happen there. One sequential observation task awaits each snapshot, checks cancellation before publication, and publishes immutable values on MainActor. It checks cancellation during preparation and never publishes a partial snapshot. Real temporary Store tests cover committed edits, Unicode names, completion/archive exclusion, rapid edits reaching the latest title, and unavailable state after Store closure.
- **P3, duplicate reversal transitions:** explicit reversal and late strong-match return share the cancellation, Search transition, suspension, agreement reset, and single ended-event operation. Their distinct reversal/late-match diagnostics remain at their callers.

The adjacent gate scan concern was assessed separately: prepared names still use the existing pure gate's linear scan. No collection-size performance profile was collected, no quantitative typing/performance claim is made, and no speculative index or asynchronous gate state machine was added in this bounded repair.

See [Standards repair review](review-fixes/standards.md).

## Spec findings

- **P1, Escape during saving/saved confirmation:** policy reversal now requires current eligibility and no composition. The native Escape callback refreshes eligibility before requesting reversal. Ineligible Escape therefore reaches the existing ordinary dismissal path, which defers an in-flight save and releases keyboard control. It does not emit a false reversal or change policy to Search. Dismissal after a committed save records a saved end irrespective of the closing key, rather than an ambiguous dismissal. Tests cover policy rejection with a preserved saved end, plus native delayed-save and saved-confirmation cases with exactly one committed note, one saved end and zero wrong/reversal/ambiguous counts.
- **P2, duplicate latency sampling:** policy remembers request IDs already sampled by timeout for the current invocation. Their stale terminal callbacks retain label/outcome/wording diagnostics with no second latency value. A new normal verdict still contributes its own sample. Tests cover cancellation acknowledgement and a non-cooperative late verdict, reconstructing persisted counts: two samples, median 800 ms, maximum 1500 ms, one timeout, no false error.

See [Spec repair review](review-fixes/spec.md).

## Automated evidence

Swift 6.3.3, Xcode 26.6; macOS arm64. All runs use temporary Stores, scripted classifiers and isolated defaults/log files. No real Jev/Foundation Models call occurs.

| Check | Result | Evidence |
| --- | --- | --- |
| Reversal policy red | Failed as intended for Escape and Backspace: false return/reversal/end, lost saved outcome | [red](review-fixes/escape-policy-red.log) |
| Reversal policy green | 21 tests passed | [green](review-fixes/escape-policy-green.log) |
| Latency red | Failed as intended for both late callback types: 3 samples, median 1500 ms, max 1700 ms | [red](review-fixes/latency-red.log) |
| Latency green | 22 policy tests passed | [green](review-fixes/latency-green.log) |
| Final focused policy/diagnostics/gate/Store source check | 33 tests in 4 suites passed | [focused](review-fixes/focused-green.log) |
| `xcrun swift build` on pinned source `b1e9cfd` | Passed | [final build](review-fixes/build-final.log) |
| `git diff --check` candidate-to-source and fixed full implementation range | Passed | Source-level check |
| Native saved-confirmation diagnostics red after unlock | Failed as intended: ambiguous count 1 and ended dismissed after committed save | [native red](review-fixes/native-red-unlocked.log) |
| Native saving/saved regression green after unlock | Both cases passed | [native green](review-fixes/native-green-unlocked.log) |
| Exact-source `xcrun swift test --no-parallel` on `b1e9cfd` | 374 tests in 49 suites passed in 61.298 s | [full suite](review-fixes/full-suite.log) |

## Native verification boundary

The native delayed-save regression's first standalone attempt and controlled rerun failed before entering the behavior under test: `NSApp.keyWindow`/editor setup was nil. These are setup failures, not meaningful behavior red results: [first](review-fixes/escape-native-setup.log), [rerun](review-fixes/escape-native-setup-rerun.log). A subsequent existing native suite attempt showed the same editor setup failure in established prefix/suggestion cases and was interrupted rather than repeating known setup failures. The parent read-only console inventory subsequently reported `console_locked=True`, `login_done=False`; that is a plausible explanation for current setup failure, not proof of the earlier exact state. Native testing slot was explicitly released while locked.

Beam explicitly handed the native slot back after unlocking. The parent read-only inventory then reported `console_locked=False`. The focused native run meaningfully reproduced the remaining saved-confirmation counting defect and passed after correction for both saving and saved-confirmation paths. They assert automated AppKit key-window state only; no physical destination/focus result is claimed. Installation and trial launch remain held. #114 real classifier tricky-input checks and #115 days-of-use trial remain pending, and #110/#105 acceptance is not complete.

The native-testing slot was explicitly released after the passing full serial suite. The source remained pinned through the final build and range checks; the later evidence commit changes documentation/logs only. Both integration and #114 candidate branch merges were rechecked after the final run and remained already up to date.

## Independent targeted review

The separate axes rechecked their original findings: [Standards](review-fixes/independent-standards.md), [Spec](review-fixes/independent-spec.md). All four original findings are resolved; the Spec follow-up also confirms the saved-confirmation end-status gap is resolved at `b1e9cfd`. These raw reports preserve each review's exact source scope and as-of verification limits. The Standards report's locked-console/native-pending wording describes its earlier review time; the subsequent unlocked focused and full serial runs above supply the final automated evidence. Neither review claims measured performance or human trial completion.
