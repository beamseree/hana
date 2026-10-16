# Issue #113 — Automatic Switch policy and native wiring

Implemented on `codex/issue-113-automatic-switch-policy`, based on integration commit `da8b098`. This ticket targets `feature/automatic-switch`, never `main`.

## Verified source and build identity

- Source and full-suite tests: `fff9a6993a21c14312a4fe8868be08b8784133ea`.
- Final test-only supplement: `f1d66daa72362e04f1bcdd9c14fa14500ce84be7`. Adds `missedManualCaptureRecordsTheLastSearchVerdictLabel`; production source is identical to the full-suite source.
- macOS 26.4.1 (`25E253`), Xcode 26.6 (`17F113`), Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`), arm64.
- Debug executable `.build/arm64-apple-macosx/debug/Hana`, SHA-256 `eeea870c5c5cc6192170a39f90bc4f7412122a559ea8a29c0ba1c195d2befdd3`.
- Full-suite test executable SHA-256 `2e65ab86b5907b77ffcf9304cbffaa35b91dafa69a7552b872233cf3e82bb10b`; final supplementary test executable SHA-256 `b8df2e25020981d4a9d1ba8620e3a5fce644e2c071c570ccb6bb9e921671c6e8`.

`xcrun swift build` passed. `xcrun swift test --no-parallel` reported **355 tests in 45 suites passed** in 61.859 s, with 11 environment-gated live-index tests skipped. See [full-suite.txt](full-suite.txt) and [build.txt](build.txt). The new pure/native focused matrix reported 31 test functions passed; the final test-only supplement passed separately (1 test in 0.410 s). All native checks use `.nativeWindowSlot`; no native test processes ran concurrently within this work.

`git merge codex/issue-110-integration` was already up to date before the full run. `git diff --check da8b098...HEAD` passed. Evidence logs are normalized to remove control characters and trailing whitespace.

## Acceptance mapping

| Required behavior | Automated evidence |
| --- | --- |
| Every-keystroke, 150 ms debounce and 500 ms pause firing | `AutomaticSwitchTests.firingStrategiesRespectTheirDelay`, `debounceClassifiesTheUnchangedBufferAfter150Milliseconds` use TestClock |
| Buffer edits cancel requests and stale responses cannot switch | `changedBufferCancelsAndMakesTheEarlierVerdictStale`, `changingOnlyUnicodeNormalizationStillCancelsTheOldRequest`; raw UTF-8 changes invalidate requests even when Swift strings compare canonically equal |
| 1.5 s timeout, including a response before the next tick | `tickAbandonsARequestAtOnePointFiveSecondsAndErrorsKeepSearch`, `responseAtTheTimeoutCannotSwitchBeforeTheNextTick` |
| All Jev thresholds, unsure, missing probability, one/two agreeing verdicts | `jevNeedsTheSelectedThreshold`, `unsureAndMissingProbabilityNeverSwitchAndAgreementRequiresTwoVerdicts` |
| Stay versus keep classifying; Note/Task/Search transitions | `afterSwitchStaysOrKeepsClassifying`, native `keepClassifyingMovesCaptureModesAndBackToSearchWithoutEditingTextOrSelection` |
| Navigation and reversal suspension, invocation reset | `navigationSuspensionIsAnOption`, `reversalKeepsSearchAndOptionallySuspends`, `escapeDismissOptionDoesNotReverseAndReinvocationClearsSuspension` |
| Enter saves or ignores for 300 ms | `enterGraceEndsAt300Milliseconds`, native `automaticCaptureKeepsTextAndSelectionAndCommitsExactlyOneItem` for both behaviors and both capture labels |
| Every wait choice; all-source wait capped at 1 s | `waitsForTheChosenSourcesAndAllSourcesHasAHardCap`; `collectionBecomingAvailableCanClassifyWithoutAnotherKeystroke` |
| Every late strong-match choice and truthful recorded outcome | `lateMatchStaysOrReturnsAndRecordsExactlyOneOutcome`, `lateStrongMatchWaitsUntilCompositionEndsBeforeRecordingAReturn`; native `lateGateBatchesRemainLiveInCaptureWithoutResurrectingSearchRows` |
| Composition blocks classification; errors keep Search | `compositionAndCurrentGateBlockAndTaskRefusesMultiline`, `tickAbandonsARequestAtOnePointFiveSecondsAndErrorsKeepSearch` |
| Toggle off never reaches classifier; explicit prefix/suggestion behavior retained with toggle on/off | native `prefixAndSuggestionKeepTheirBehaviorAndRecordMissedOnlyWhenEnabled`; existing prefix/suggestion/Enter suites pass unchanged in the full run |
| Automatic transitions preserve raw text and UTF-16 selection; save creates exactly one note/task | native `automaticCaptureKeepsTextAndSelectionAndCommitsExactlyOneItem` through the real Capture Session and temporary Store |
| Escape and Backspace keep text; Escape may reverse once or dismiss | native `automaticReversalKeepsTextAndDoesNotCountTheSameManualCaptureAsMissed`, `escapeAfterAnAutomaticSwitchReversesOnceOrDismissesAsConfigured` |
| Held Enter, pending launch and multiline Task guards | native `heldEnterCancelsClassificationAndCannotTurnIntoAnAutomaticCapture`, `pendingLaunchCancelsClassificationBeforeItsVerdictCanSwitch`, `taskVerdictCannotFlattenPastedMultilineText` |
| Every behavior option has a nested radio submenu, takes effect next invocation, no working window or policy change | native `everyBehaviorSubmenuPersistsARadioChoiceForTheNextInvocation`, existing submenu toggle/count test |
| Content-free diagnostics and correct counts/last-verdict provenance | `recordedPolicySessionHasNoInputAndGateOnlyEventsDoNotAddLatencySamples`, native save/reversal/late-match tests, `missedManualCaptureRecordsTheLastSearchVerdictLabel`, existing `AutomaticSwitchDiagnosticsTests` |

All defined verdict outcomes are exercised at the policy boundary: switched, below-threshold, unsure, awaiting-agreement, blocked, stale, multiline, suspended, error and timeout. An already-current-mode verdict is recorded as blocked, preserving its label and omitting a gate reason when no gate blocked it. Gate-only outcomes omit classifier latency rather than adding artificial zero samples. A reversal followed by a manual capture of the unchanged text does not increment missed; editing that text makes a later manual capture eligible again. Manual transitions cancel classification even for blank buffers.

## Integration boundaries

`Classifier.swift` defines the cooperative async classifier boundary and a content-free `ClassifierFailure`. `ScriptedClassifier.swift` supplies controlled verdicts, failures and cancellation in tests. `MacInteraction` accepts an optional `classifierFactory` keyed by the invocation's `AutomaticSwitchOptions`. Its default is nil: persisted preferences cannot make default native test constructors call real models. Production adapters and explicit normal-launch installation of the factory belong to #114.

Automatic effects use Capture Session's existing capture and return transition functions. The native editor instance, text, selection, undo handling, multiline refusal and idempotent Store save behavior remain on the existing path. Search batches remain live as gate input during automatic capture without displaying Search rows; capture edits re-query the gate when keep-classifying is selected.

## Red/green record and limitations

The first tracer test failed to compile before the new policy interface existed ([red-policy-interface.txt](red-policy-interface.txt)), then passed ([green-policy-interface.txt](green-policy-interface.txt)). Behavioral red/green loops caught:

- A late-match return being recorded while composition prevented the actual return: [red](red-late-match.txt), [green](green-late-match.txt).
- A deadline response switching before the next tick: [red](red-timeout.txt), [green](green-timeout.txt).
- Collection availability requiring another keystroke: [red-gate-ready.txt](red-gate-ready.txt), covered green in [focused-pass.txt](focused-pass.txt).
- Canonically equivalent but byte-different edits leaving old requests current: [red-unicode.txt](red-unicode.txt), covered green in [focused-pass.txt](focused-pass.txt).

These iteration logs describe uncommitted development stages; the exact committed verification identities are above. The first native reversal test also exposed a fixture synchronization mistake: sending a snapshot before the replacement stream subscribed. That initial failure is retained in [native-initial-fixture-sync-failure.txt](native-initial-fixture-sync-failure.txt); the fixture now waits for the replacement subscription before sending, and the focused/full suites pass. This is not claimed as a production defect.

The human authorized automated native tests and held installation. The native slot was explicitly released after the full run and again after the single supplementary diagnostics assertion. No installed app was launched, no installation was performed, and neither real classifier was called. Native checks establish automated AppKit responder/editor behavior and committed fixture Store state; they do not establish physical keyboard focus, a foreign-app typing destination, real-model quality, physical latency, or Beam's days-of-use acceptance. Those remaining classifier/trial checks belong to #114/#115.
