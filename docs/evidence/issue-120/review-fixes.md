# Issue #120 — Integration review fixes

## Session request counts for every firing strategy

The #122 evidence promises `autoswitch.session.requestsSent` for every strategy, but the non-Word-paced `fireIfDue` path emitted classification requests without incrementing the count. This made every-keystroke, debounced and on-pause trial sessions report zero requests for both Foundation Models and Jev.

The fix adds one increment at the successful request-emission point, after all eligibility, composition, in-flight and gate checks. No firing condition, delay or classification behavior changes. Word-paced retains its existing increment.

**Agreed seam:** `AutomaticSwitch.handle(event) → [effect]`, with `TestClock`; observations are classification effects and the session diagnostic effect. No private state, native windows or real classifier is used.

**Red:** `AutomaticSwitchSessionCountTests.sessionCountsRequestsForTheOtherFiringStrategies` failed in all six combinations (three firing strategies × two classifiers). Each session emitted the expected requests, but the diagnostic reported `[0]` instead of `[2]`, and the next invocation reported `[0]` instead of `[1]`. [Red output](session-count-red.log).

**Green:** Apple Swift 6.3.3, arm64 macOS 26, 2026-10-15:

```sh
xcrun swift test --no-parallel --filter '(AutomaticSwitchSessionCountTests|AutomaticSwitchWordPacedTests|AutomaticSwitchTests|AutomaticSwitchDiagnosticsTests)'
```

Passed **52 tests in four suites**, including all six new cases. The test verifies a completed request plus a still-running request count as two, a repeated dismissal emits no second session row, and the next invocation starts its count fresh at one. Existing Word-paced and legacy firing tests remain passing. [Green output](session-count-green.log).

The new test first ran against integration revision `17581dceec1ed27513febd93ab40c9f000292d32`; the one-line implementation and test are recorded in this branch's `Count session requests for all firing strategies` commit. Native behavior, physical latency and classifier quality were not tested in this change.

## Formal review resolution

The standards/spec review of integration `6cea5a2` raised two P2 policy findings and one P3 fixture-duplication finding. All are addressed in code revision `226d710225ab21dbe9c55b97a5ffca2309229202`.

### P2: agreement from replaced words

Word-paced confidence now tracks the previous handled answer's normalized prefix alongside its label. A later answer agrees only if its prefix still starts with those previous words. Editing away those words clears the agreement history. The existing candidate marker still ensures that Search-source waits, repeated ticks and held answers do not count one answer twice.

`AutomaticSwitchReviewPolicyTests.replacingThePreviousAnswersWordsBreaksBorderlineAgreement` reproduced an incorrect switch after both an unrelated replacement (`call mom` → `buy milk`) and deleting before the prior answer's words (`call mom` → `call mo`). Each new 0.80 answer now waits; a subsequent answer for its appended words can agree and switch. [Red](agreement-prefix-red.log), [focused green](agreement-prefix-green.log): 37 tests in four suites, including cache, held deletion answers and withdrawal coverage.

### P2: duplicate cancelled work across bars

Launch-wide in-flight accounting now retains a SHA-256 fingerprint of normalized request text until the terminal callback releases its slot. It retains no additional raw text beyond the existing answer-cache keys, and writes no fingerprint to diagnostics or disk. This check includes cancelled work in the current bar and unfinished work from a closed bar. A blocked duplicate takes the existing newest-only waiting slot and can send once the old request actually ends.

The public-seam regressions deliberately withhold cancellation acknowledgement, exposing the same noncooperative-provider timing without making a classifier call:

- `retypingCancelledTextWaitsUntilItsRequestActuallyFinishes`: delete and retype the cancelled text; no duplicate request at the pause; exactly one new request after its terminal callback.
- `anIdenticalRequestFromAClosedBarWaitsForItsTerminalCallback`: reopen while the old request remains; whitespace/NFC-equivalent text waits despite a spare slot; terminal completion and `.slotReleased` release exactly one request.

Both failed before the fingerprint check. [Red output](in-flight-dedupe-red.log). The combined policy run passed **81 tests in seven suites**, including existing cache, held confidence, prefix agreement, deletion, withdrawal, wake-up and backoff coverage. [Green output](review-policy-green.log).

```sh
xcrun swift test --no-parallel --filter '(AutomaticSwitchReviewPolicyTests|AutomaticSwitchWordPacedTests|AutomaticSwitchWordCacheTests|AutomaticSwitchDeletionTests|AutomaticSwitchWithdrawalTests|AutomaticSwitchWakeUpTests|JevBackoffTests)'
```

### P3: shared native fixture

`JevWordPacedNativeFixture` now owns isolated defaults, option initialization, temporary diagnostics, teardown and Mac Interaction construction for all three Word-paced native suites. Its empty Search source always publishes a terminal `.ready` batch before finishing. Option customization is an explicit initializer closure; launch memory is an explicit interaction override. Withdrawal tests explicitly select `enterBehavior = .saves`, while tracer/deletion tests retain their previous defaults.

With the user's granted exclusive native slot, Apple Swift 6.3.3 on arm64 macOS 26, 2026-10-15, code revision `226d710`:

```sh
xcrun swift test --no-parallel --filter '(JevWordPacedNativeTests|JevWordPacedDeletionNativeTests|JevWordPacedWithdrawalNativeTests)'
```

Passed **15 tests in three suites** in 6.100 seconds. [Native output](review-native-green.log). Only these three native suites ran; they use fixture stores and fake Jev. The native slot was released immediately afterward. No app installation, live API request, physical-focus observation, perceived-latency measurement or classifier-quality claim is included.

Both original reviewers independently rechecked `226d710`. The spec reviewer confirmed both P2 findings resolved; the standards reviewer confirmed the P3 fixture finding resolved. Neither reported a new actionable finding. Recheck reports remain at `/tmp/hana-issue-120-context/spec-recheck.md` and `standards-recheck.md`.

## Evidence text normalization

Added/modified `.log` and `.txt` evidence since base `f39834c` was checked for CR, U+2028 and trailing spaces/tabs. Before normalization, exact raw bytes were archived under `/tmp/hana-issue-120-context/raw-evidence-226d710/`, preserving repository-relative paths; its `manifest.json` lists raw SHA-256 hashes and the changed files. CRLF is normalized to LF; remaining CR and U+2028 are represented by literal `\r` and `\u2028`; trailing spaces/tabs are stripped. This includes the previously flagged #122 `macos-tests.log` and #125 `red-4.txt`. Pass/fail content is unchanged; the archive preserves any significant fixture whitespace. Git diff whitespace validation is recorded with the final branch check.

Exactly those two existing log files required normalization; the new review logs needed no changes. `git diff f39834c --check` passed after normalization.
