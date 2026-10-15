# Issue #123 — Word-paced launch cache and confidence

Part of #120. Tested code revision: `ceb56024db31dd5180b26a864334368940a40e98`.

The launch-wide Jev memory retains up to 64 successful answers in memory, keyed by normalized text, classifier wording version and model. Reads refresh LRU order. Failed, cancelled and timed-out requests never populate the cache. A valid timely success arriving after a newer answer is cached for future use but cannot switch the current bar. Opening another bar reuses the memory; no cache is persisted.

Word-paced handles an exact cache hit as soon as the edit or newly allowed gate permits it, without sending a request or waiting for the typing pause. Cache verdict rows carry `cached: true` and no latency. Gate, composition, eligibility, threshold and multiline Task rules still apply.

With the one-agreement option, Word-paced switches at or above `max(threshold, 0.90)` immediately. A lower answer at or above the threshold needs a previous consecutive agreeing answer. With the two-agreement option every answer needs that confirmation. Agreement is recorded once when an answer is handled, including while Search sources are settling; repeated ticks or whitespace do not manufacture another answer or request. Other strategies retain their previous confidence rules.

## Automated verification

On 2026-10-15, Apple Swift 6.3.3, arm64 macOS 26:

```sh
xcrun swift test --no-parallel --filter 'AutomaticSwitchWordCacheTests|AutomaticSwitchWordPacedTests|AutomaticSwitchTests|AutomaticSwitchWakeUpTests|AutomaticSwitchDiagnosticsTests'
```

**Passed: 76 tests in five suites.** Full output: [policy-tests.log](policy-tests.log). The command compiled the package and test target; only the five pure-policy/diagnostics suites executed. The existing `MacInteractionTests.shouldFail` sendable-capture warning also appeared while compiling the unchanged test target.

| Acceptance item | Tests through the policy or diagnostics seam |
| --- | --- |
| Cached answer switches with no request in a new bar | `anAnswerFromAnEarlierBarSessionSwitchesWithoutARequest`, `aCachedAnswerAppliesAsSoonAsTheGateAllows` |
| Failure is not cached | `failuresAreNeverCached` (network, authentication, rate limit, malformed response, other) |
| Different wording or model misses | `differentWordingOrModelMissesTheCache` (both cases) |
| LRU eviction after 64 answers | `theSixtyFifthAnswerEvictsTheLeastRecentlyUsedEntry`: touches item 0, inserts item 64, observes item 1 requires a request and item 0 still switches from cache |
| Normalization uses trim, collapsed whitespace, NFC and preserved case | `normalizationSharesTheCacheButPreservesCase` |
| Newer answer still wins; older success remains reusable | `anOlderSuccessfulAnswerIsCachedEvenWhenANewerAnswerAlreadyWon`, existing `answerOlderThanAHandledAnswerDoesNotSwitch` |
| 0.90 and above switches immediately | `clearAnswersSwitchAtOnce` (0.90, 0.95, 1.0) |
| Borderline waits for consecutive agreement without resending | `aBorderlineAnswerWaitsForTheNextAgreeingAnswerWithoutResending`, `consecutiveBorderlineAnswersAgreeWhileSearchSourcesAreStillSettling` |
| Disagreement, unsure and below-threshold break agreement | `disagreementRequiresANewConsecutivePair`, `unsureAndBelowThresholdAnswersBreakAgreement` |
| Two agreeing answers never repeat the same request | `twoAgreeingClearAnswersDoNotResendTheSameText`, existing `secondAgreeingVerdictComesFromTheNextAnswerNeverAResend` |
| Threshold 0.95 governs | `thePointNineFiveThresholdStillGoverns` |
| Multiline Task guard is unchanged on cache hit | `multilineTaskCacheHitsStillCannotSwitch` |
| Cache verdict is marked, latency-free and content-free | `cacheHitsAreMarkedWithoutLatencyOrInputText`: only the live answer contributes a 40 ms sample; the cached row has no latency or fixture text |

## TDD record

Observed failures before each implementation slice, followed by a passing focused rerun:

- Cross-session cache: the second bar produced no immediate switch.
- Diagnostics: the cached verdict JSON lacked `cached: true`.
- LRU: the 65th answer left item 1 cached instead of requiring a request.
- Identity: both changed wording and changed model incorrectly reused the previous answer.
- Confidence: a first 0.80 answer switched instead of waiting for agreement.
- Source settling: two consecutive 0.80 answers did not switch after the gate settled.
- Gate allowance: an existing cached answer waited instead of switching when the gate became allowed.
- Out-of-order success: the older successful answer was unavailable to the next session.

The broad run initially caught one new test constructing a replacement edit after two spaces while expecting an append boundary. The fixture was corrected to preserve both spaces; no scheduling behavior was changed for that correction.

## Limits

These are fake-clock policy and temporary diagnostic-file checks. No live Jev request, app install, window interaction, perceived-latency claim or classifier-quality claim is part of this evidence. Deletion bursts and failure backoff integrate under #124 and #126 and require an integrated rerun. Beam's physical trial remains separate under #115/#128.

## Final integration validation — 2026-10-15

At `b31ae3260922790218cbbf7f38b51a62c7573311`, `xcrun swift test --no-parallel` passed with **491 tests in 66 suites** (74.511 s), including all native Word-paced tests. Eleven unrelated environment-gated live-index checks remain skipped. This supersedes earlier native-unrun status in this ticket’s initial implementation phase. [Combined record and logs](../issue-120/validation.md). Physical focus, perceived/live latency and normal-use quality remain #128/#115 human evidence.
