# Issue #122: Word-paced Jev firing (tracer)

Part of #120. **Word-paced** replaces **Jev pipeline (100 ms, up to 3)** in the Automatic switch submenu's Fires options. Implemented on `feature/automatic-switch`, never `main`.

## What changed

- **Policy (`AutomaticSwitch`).** With Jev and Word-paced, the pipeline's scheduling and policy branches are gone. In their place:
  - **Normalization** (`AutomaticSwitch.normalized`): Unicode NFC, trimmed, whitespace runs collapsed to one space, case kept. Request text, word count, duplicate checks and prefix checks all use it.
  - **Send conditions:** a request is sent only when the policy can classify (eligible, not suspended, not composing, Search or "Keep classifying"), the normalized text has at least two words, the gate allows, no valid request in flight has identical text, and the text differs from the last handled answer's text.
  - **Word boundary:** an append whose last character is whitespace or punctuation, following a word character, sends at once. Apostrophes and hyphens join a word (`don't`, `e-mail`), so they never complete one.
  - **Pause:** every other edit schedules a send at `JevLaunchMemory.pauseThreshold` after it: `max(120 ms, 1.4 × median)` over the last 20 typing gaps, or 180 ms until five gaps exist. The value is computed in integer `Duration` arithmetic (`× 7 / 5`), so the fake-clock boundaries are exact.
  - **Capacity:** at most two requests in flight, counted by the launch memory, so leftovers from closed bar sessions count until their work ends. With both slots busy, the text takes the single waiting slot, replacing older waiting text. When a slot frees, the waiting text is sent if the current text still starts with it.
  - **Answer validity:** an answer applies only while the current normalized text starts with its text, and only if its sequence is newer than the newest handled answer. Appending keeps all requests. Any other edit cancels exactly the requests whose text is no longer a prefix. The ticket allowed cancelling all of them; the selective rule is the same prefix test, applied at edit time.
  - **Deadline:** 1.2 s. An answer at or after 1.2 s, or a tick at 1.2 s, records a timeout. This follows the existing 1.5 s convention, where a tick at exactly the deadline times out. A timed-out request keeps its slot until the provider acknowledges.
  - **After a switch** with "Stay in that mode", every request is cancelled and nothing more is sent.
  - **"Agreeing verdicts: 2"** never resends the same text. The next answer, for longer text, may agree.
  - **Unchanged from the pipeline:** a gate block cancels every request, and a later "allowed" schedules a pause from the last edit. Clearing the bar returns an automatic capture to Search and lifts reversal suspension.
- **Shared launch state (`JevLaunchMemory`).** One per `MacInteraction`, which lives for the app launch. It is injected into each session's policy. It holds the last 20 typing gaps and the IDs of in-flight requests, never text, and is never persisted.
  - A typing gap is the time between two consecutive appends in one session. A paste counts as one insertion, and any other edit restarts the measurement.
- **Mac Interaction.** Each classification task frees its launch-wide slot when it ends. If its bar session has already closed, the current session's policy then gets `.slotReleased` so a waiting text can go out. A `.classify` effect with no current invocation frees its slot at once.
- **Shared transport (`JevSharedTransport`, renamed from `JevPipelineTransport`).** The cap is two, and the 100 ms start spacing is removed: a free slot admits the next waiter at once. A slot is taken at admission and released when the transport exits, cancelled or not. A waiter cancelled before admission never sends. Only Word-paced Jev uses it, as the pipeline did.
- **Menu and options.** The Fires item is **Word-paced**, enabled only while Jev is the classifier. Choosing Foundation Models while Word-paced is selected falls back to Debounced (150 ms). `AutomaticSwitchOptions.Firing` decodes a stored `pipelinedJev` as `wordPaced`, so the rest of the saved snapshot is kept rather than reset to defaults. Existing log rows written with the pipeline value also still decode, so they keep counting. With Foundation Models, a Word-paced value behaves as debounced, as the pipeline value did.
- **Diagnostics.**
  - New row `autoswitch.session` with `requestsSent`, recorded once per bar session with automatic switch on, for every strategy.
  - A cancelled request's later stale row carries no latency, for every strategy (a #119 review fix). Timeouts keep their single latency sample as before.
  - A one-word trigger records nothing. A gate-blocked trigger records `blocked` as before.
  - Rows remain content-free.

## Acceptance mapping

| Criterion | Automated evidence (not yet run; see below) |
| --- | --- |
| Word-boundary send happens immediately | `AutomaticSwitchWordPacedTests.wordBoundarySendsImmediately` (space, `.`, `?`), `apostrophesAndHyphensDoNotCompleteAWord` |
| Pause send at exactly the adaptive threshold and not 1 ms before, incl. 120 ms floor and 180 ms before five gaps | `pauseSendsAtExactlyTheAdaptiveThreshold` (150 ms gaps → 210 ms; 50 ms gaps → 120 ms floor; four gaps → 180 ms), `typingGapsAreSharedAcrossSessionsInTheLaunch`; wake-up time in `AutomaticSwitchWakeUpTests.wordPacedPauseAndDeadlineAreReportedAndBusySlotsStillReportThePause` |
| No send for one normalized word (`remind `), gate-blocked text, composition, after a staying switch | `noSendForOneNormalizedWord`, `noSendForGateBlockedText`, `noSendWhileComposing`, `noSendAfterASwitchThatStays` |
| No duplicate when a pause is followed by a space, incl. NFC vs NFD | `aPauseFollowedByASpaceSendsOnce` (in flight, then answered), `nfdAndNfcAreTheSameText` |
| Capacity of two plus one newest-only waiting slot, incl. leftovers | `capacityIsTwoPlusOneWaitingSlotHoldingOnlyTheNewestText`, `waitingTextIsDroppedWhenItIsRemoved`, `capacityCountsRequestsLeftOverFromAnEarlierSession` |
| Answers for earlier words switch; removed text and older-than-handled don't | `answerForEarlierWordsSwitches`, `appendingKeepsEveryRequestRunning`, `answerForRemovedTextDoesNotSwitch` (`call mo`, `call`, `buy milk`), `answerOlderThanAHandledAnswerDoesNotSwitch` (newer verdict or failure) |
| 1.2 s deadline | `answerLaterThanOnePointTwoSecondsIsATimeout` (1199 ms switches, 1200 ms times out), `deadlineTimesOutAndKeepsTheSlotUntilTheProviderAcknowledges` |
| Transport: cap of two across independent sessions; no start spacing; cancelled waiters never send | `JevSharedTransportTests.independentClientsShareTwoSlotsWithNoStartSpacing`, `cancelledActiveRequestsHoldSlotsUntilNoncooperativeTransportExits`, `cancelledWaitingRequestNeverSendsAndSurvivingWaitersKeepTheirOrder` |
| Native: selecting Word-paced and typing a phrase sends only boundary and pause requests | `JevWordPacedNativeTests.typingAPhraseSendsOnlyBoundaryAndPauseRequestsAndASwitchKeepsTextAndSelection`: exact request list `call mom` (pause), `call mom tomorrow` (pause), `call mom tomorrow at` (boundary). The session row reports `requestsSent` 3, and no requests follow the staying switch. Also `requestsLeftOverFromAClosedBarStillCountTowardTheCapOfTwo` |
| Native: a switch keeps text and UTF-16 selection | The same test, plus `prefixAnswerKeepsTheCurrentBufferAndSelectionAndEnterSavesExactlyOnce` |
| Native: Enter, held-Enter and pending-launch guards still hold | `prefixAnswerKeepsTheCurrentBufferAndSelectionAndEnterSavesExactlyOnce` (300 ms grace, one save). `AutomaticSwitchInteractionTests.heldEnterCancelsClassificationAndCannotTurnIntoAnAutomaticCapture` and `pendingLaunchCancelsClassificationBeforeItsVerdictCanSwitch` now also run with Word-paced Jev (`wordPaced: true`) |
| Native: Fires menu shows Word-paced, disabled for Foundation Models; stored pipeline value migrates | `JevWordPacedNativeTests.firesMenuShowsWordPacedOnlyForJevAndMigratesAStoredPipelineChoice`, `ClassifierMenuTests.menuReflectsAvailabilityAndOnlyEnablesJevAfterKeySaved`, `AutomaticSwitchInteractionTests.everyBehaviorSubmenuPersistsARadioChoiceForTheNextInvocation`, `AutomaticSwitchDiagnosticsTests.storedPipelineChoiceMigratesToWordPaced` |
| Diagnostics: requests-sent count per session; cancelled requests add no latency; no input text | `AutomaticSwitchWordPacedTests.sessionRecordsRequestsSentAndCancelledRequestsAddNoLatency`, `AutomaticSwitchDiagnosticsTests.sessionRowCountsRequestsAndLegacyPipelineRowsStillCount`, `cancelledRequestsOfEveryStrategyAddNoLatencySample`; native typing test checks the session row and absence of typed text |
| No automated test calls the real Jev API | Policy tests have no classifier. Native tests use `ScriptedClassifier` or the local `HeldJev` fake through `classifierFactory`. Transport tests use a held fake transport. |

Changed existing tests, beyond the parametrized interaction tests above: the pipeline-specific policy and wake-up tests were removed with the pipeline. `firingStrategiesRespectTheirDelay` now treats Word-paced under Foundation Models as debounced. The pipeline's clear-to-rearm test moved to `AutomaticSwitchWordPacedTests.clearingAutomaticCaptureReturnsSearchAndRearmsDespiteReversalSuspension`. The transport and native suites were renamed to `JevSharedTransportTests` and `JevWordPacedNativeTests`.

## Verification status and limitations

**Nothing in this record has been compiled or executed yet.** The work was done in a Linux cloud container with no Swift toolchain. `download.swift.org` is blocked by its network policy, and running a toolchain fetched from an image mirror was not permitted. The package targets macOS 26 with AppKit, so neither `xcrun swift build` nor `xcrun swift test` could run. The source was checked by reading and by tracing each fake-clock expectation against the policy's state transitions. That is not test evidence.

Remaining before #122 can close:

1. `xcrun swift build` and `xcrun swift test --no-parallel` on a Mac. Record the source revision, toolchain, pass counts and logs in this directory, as for #121.
2. Beam's trial observations, kept separate from the automated results: requests per session (`autoswitch.session` rows), how the switch timing feels, and wrong and missed switch counts compared with the pipeline candidate. These belong to #115.

No real classifier was called, and no app was installed or launched. The native tests establish AppKit command delivery and automated timing only, not physical keyboard focus, perceived latency or classifier quality.
