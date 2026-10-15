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
