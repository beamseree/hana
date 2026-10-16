# Issue #121: Automatic switch reports its next wake-up time

Part of #120. Prefactor: no firing strategy changes behaviour. Implemented on `feature/automatic-switch`, never `main`.

## What changed

- `AutomaticSwitch.nextWakeUp` reports the earliest time, on the policy's own `now` clock, when a `.tick` can change anything. It reports nil when nothing time-based is pending, the session is inactive, or automatic switch is off. It considers:
  - a debounce, pause, pipeline-spacing or agreement-retry deadline (`due`). This counts only while it can fire. A non-pipelined deadline behind an in-flight request, or a pipeline deadline with all three slots full, waits for that request's terminal event, not for time.
  - each valid in-flight request's 1.5 s timeout;
  - the 1 s all-sources wait cap while a verdict is held for unsettled sources;
  - the end of the 300 ms Enter grace window after an automatic switch. A new `enterGraceEnds` field holds it. The switch sets it, the switch ending clears it, and the first `.tick` at or after it clears it. The `.enter` decision itself is unchanged.
- `MacInteraction` no longer runs the 25 ms loop. After every batch of policy effects, `performAutomaticSwitch` calls `scheduleAutomaticSwitchWake()`, which:
  - converts the reported time to a `ContinuousClock.Instant` from the session epoch;
  - keeps the pending sleep if the time is unchanged, and otherwise cancels it and sleeps until exactly the new time;
  - schedules nothing when the policy reports none.

  A wake sends one `.tick`. Dismissal cancels the sleep. `.tick` is still an accepted event, so existing tests are unaffected.

Every tick-dependent path is covered by a reported time: timeouts, pending-candidate re-application (whose only time dependence is the all-sources cap) and `fireIfDue`. Every tick at a reported time makes progress, by firing, timing out, consuming the candidate or clearing the grace end. So a deadline in the past cannot cause repeated immediate wake-ups.

## Acceptance mapping

| Criterion | Automated evidence |
| --- | --- |
| Each result with a pending deadline reports the earliest wake-up time; none when nothing is pending | `AutomaticSwitchWakeUpTests.nothingPendingReportsNone` (fresh session, settled verdict, dismissed, toggle off) and every test below |
| Debounce, pause and pipeline deadlines | `firingDeadlineIsTheReportedWakeUpAndFiresExactlyThen` (every keystroke, 150 ms, 500 ms; nothing fires 1 ms early, the request fires at the reported time); `pipelineSpacingDeadlineIsReportedAndFullSlotsReportOnlyTimeouts` (100 ms start spacing; full slots report only the earliest timeout) |
| 1.5 s request timeout | `requestTimeoutIsReportedAndConsumedAtOnePointFiveSeconds`; the firing and pipeline tests also check the remaining timeout |
| 1 s all-sources wait cap | `allSourcesWaitCapIsReportedOneSecondAfterTheEdit` |
| End of the 300 ms Enter grace window | `enterGraceWindowEndIsReportedThreeHundredMillisecondsAfterTheSwitch`, `enterThatSavesReportsNoGraceWindow` |
| Earliest of several | `earliestOfSeveralPendingDeadlinesIsReported` (debounce before grace end, then grace end before the request timeout, then the timeout alone) |
| Same moments as the 25 ms ticks | `wakingOnlyAtReportedTimesMatchesTheEarlier25MillisecondTicks` drives one script both ways. Debounce, two-verdict agreement and the switch give identical effects at identical times, with exactly three wake-ups. |
| No fixed 25 ms loop; sleep until the reported time, replace it, cancel on dismiss | Source: `automaticSwitchTicker` removed; `scheduleAutomaticSwitchWake()`. Native `newerWakeUpTimeReplacesThePendingSleep`, `dismissCancelsThePendingWakeUp` |
| Native fake-classifier test: debounced request fires without periodic ticks; no wake-up while nothing is pending | Native `debouncedRequestFiresAtItsReportedTimeAndNothingWakesWhileNothingIsPending`. Over 200 ms the empty bar has no scheduled wake and none is delivered. Typing schedules one at the 150 ms debounce, and exactly one wake-up starts the request. After the verdict nothing is scheduled, and no wake-up happens over a further 200 ms. |
| Existing policy, interaction and diagnostics tests pass unchanged | No existing test file was modified. `AutomaticSwitchTests`, `AutomaticSwitchInteractionTests` and `AutomaticSwitchDiagnosticsTests` all passed in the full serial run recorded below. |

## Verification status and limitations

The initial implementation was written and traced in a Linux cloud container without a Swift toolchain. The macOS validation below supersedes its earlier unrun status.

### macOS validation — 2026-10-15 (Asia/Bangkok)

- Tested source: `2042478c6c96a22f09911416fea3474d22f56671`, after `git pull origin feature/automatic-switch` fast-forwarded the clean worktree to the requested head.
- Host: macOS 26.4.1 (25E253), Apple silicon; target `arm64-apple-macosx26.0`.
- Toolchain: Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3 clang-2100.1.1.101`), swift-driver 1.148.6.
- `xcrun swift build`: **passed**, exit 0; build completed in 25.05 s. Full output: [build.log](build.log).
- `xcrun swift test --no-parallel`: **passed**, exit 0. Swift Testing reports **403 tests in 53 suites**, with **11 environment-gated live-index tests skipped**, in 74.459 s. Full compilation and test output: [tests.log](tests.log). The separate XCTest discovery summary of zero tests is not the Swift Testing result.
- New fake-clock suite `AutomaticSwitchWakeUpTests`: all nine test functions passed (the firing-deadline test covers three firing strategies).
- New native suite `AutomaticSwitchWakeUpInteractionTests`: all three tests passed in 1.423 s: idle/debounced wake-up, replacement of a pending sleep, and cancellation on dismiss. The suite is declared `@Suite(.serialized, .nativeWindowSlot)` and ran alongside the existing native suites in the same serial invocation.
- Existing automatic-switch policy, interaction and diagnostics suites all passed.
- Test compilation emitted a warning at `Tests/HanaTests/MacInteractionTests.swift:423`: `'shouldFail' mutated after capture by sendable closure`. It did not fail compilation or tests; the complete diagnostic is retained in `tests.log`.

No real classifier was called for the issue-specific wake-up tests, and no installed app was replaced or launched for manual validation. The native tests use `ScriptedClassifier` and a temporary Store and present AppKit windows through the test process. They establish automated AppKit timing only, not perceived latency. The skipped live-index checks are not claimed as verified.
