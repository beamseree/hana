# Issue #114 — classifier adapters and tricky-input check

Date: 2026-10-15. Parent: #110. Target: `feature/automatic-switch`, never `main`.

## Status and evidence boundary

**Follow-up, 2026-10-15:** the candidate was subsequently installed with Beam's authorization, and both real-provider checks completed. See [installed-candidate reports and settings/provenance](interactive/README.md). PR #119 remains draft; normal-use human acceptance remains pending. The rest of this document records the earlier automated verification phase and its then-current installation hold.

The code and automated adapter, Keychain, submenu, and fixture-report checks are implemented. **Interactive acceptance remains pending.** No real Jev API request or Foundation Models inference, installed trial build, or deliberate tricky-input provider run occurred in this work. The user authorized native automated tests only and held installation/trial launch. This record does not satisfy the criterion requiring a report from each available classifier on Beam's Mac; #114 must remain open/draft until that evidence exists.

## Implementation

- `ClassifierWording.swift` owns the shared instructions/criteria and closed `automatic-switch-v1` wording token. Jev uses the required existing-item Search criterion, `Other`, and pinned `jev-1.13.0` model. Its injected transport returns HTTP bytes/status; the adapter checks all four probabilities, finite/range/sum constraints, winning choice, and response model. A verdict uses the winning probability, not the provider's separate confidence statistic. Error values contain no body or input.
- `FoundationModelsClassifier.swift` maps installed-SDK availability, generates separate three/four-case enums, maps guardrail/refusal failures, checks cooperative cancellation, and consumes the exact prewarmed session once. Every later request owns a fresh session. Prewarm lead time/effectiveness and physical inference cancellation are unmeasured.
- `JevKeychainStore.swift` uses a nonsynchronizing generic-password item; updates replace its data, and removal is idempotent. The secure-field alert includes the TypeSafe US/no-fixed-retention notice. No key is recovered into the field or persisted in preferences/logs.
- Normal `HanaApp` launch alone installs the real services/factory. Validation launch paths leave it nil. `MacInteraction` defaults still cannot call a real model from persisted options; the factory is evaluated once per enabled invocation. Submenu availability/key status refreshes on opening, Jev is disabled without a key, and these controls open no working window.
- `TrickyInputCheck` has 30 fixed inputs and a fixed fixture collection. Active `Weekend ideas`/`Book dentist` block; completed `Send invoice` and archived `Old travel notes` are excluded. Gate evaluation is shown independently of classifier requests. Requests run sequentially and do not receive live Collection data or any automatic-switch event sink. The background report writer saves a plain-text report under `~/Library/Logs/Hana/`, restricts it to mode 0600, and the deliberate menu action reveals it in Finder.
- Each check request has a 1.5-second abandonment boundary. If an underlying model ignores cancellation, the check returns a timeout row and stops issuing inference. Remaining rows retain their gate result and explicitly say `not-run`, with `unmeasured` latency. This prevents overlap with an abandoned provider request and does not claim immediate hardware cancellation.

## Automated evidence

Final tested code/test revision: `3761fd31c545e69d4f8ec5b6d562e960e571ec5e`. Production source is unchanged from `ac8bdecc71cdb122848e85e5ea36bb2e251afe59`; later changes correct the pre-existing options-test fixture for the new saved-key requirement and strengthen the key privacy assertion.

Environment: macOS 26.4.1 (25E253), arm64; Xcode 26.6 selected at `/Applications/Xcode-26.6.app/Contents/Developer`; Apple Swift 6.3.3. The executed debug XCTest bundle binary SHA-256 was `0703ddfabad786ed2114b90df87fd3d5ad8b0c6912826ad724dd4e8892bad971` (`.build/arm64-apple-macosx/debug/HanaPackageTests.xctest/Contents/MacOS/HanaPackageTests`); this identifies an automated test artifact, not an installed Hana build. No installation or normal app launch was part of verification. Native checks held the authorized exclusive slot and ran serially.

| Acceptance | Public seam and evidence |
| --- | --- |
| Jev URL/method/model/Bearer/one-choice shape and probabilities | `ClassifierAdapterTests.jevUsesPinnedChoiceRequestAndWinningProbability` uses only a stub transport; the literal response's confidence differs from its winning probability. |
| Other → unsure | `jevOtherMapsToUnsure`. |
| 401/429/other HTTP, malformed bodies/distributions/model, timeout | `jevHTTPFailuresAreContentFree`, `jevMalformedResponsesFail`, `jevTimeoutAndCancellationFailWithoutVerdict`. |
| Cancellation cannot publish a result | Jev and Foundation tests include a runner/transport that cancels the task then returns a verdict anyway. |
| Isolated Keychain save/read/replace/remove and no key in defaults/events | `JevKeychainTests` uses a unique service, reads the saved key into the stubbed Jev request, records its returned verdict, checks both preferences and recorded rows, and deletes the service item. |
| Availability submenu text and unavailable model does no inference | `availabilityText`, `foundationUnavailableNeverRunsModel`, `ClassifierMenuTests`. |
| Warmed-session ownership; typed Foundation errors | `foundationConsumesWarmedSessionThenUsesFreshSessions`, `foundationRunnerFailuresStayTyped`. SDK enum/macro/error matching also compiles against the installed framework; fake failures do not constitute an actual model refusal/guardrail observation. |
| Fake report structure, fixture gates and bounded timeout | `TrickyInputCheckTests` checks 30 rows, escaped multiline input, gate/label/score/latency fields, and an uncooperative fake whose timeout prevents any subsequent inference and marks latency unmeasured. |
| Menu key enablement, radio persistence, no working-window/policy change | `ClassifierMenuTests`; existing options-submenu regression test now supplies a unique saved test key. The secure alert itself has source/compiler evidence only; it was not interactively opened. |
| Real-provider interactive checks with reports | Subsequently completed via the installed candidate; see [raw reports and limitations](interactive/README.md). |

TDD logs retain missing-adapter/report red states and focused green checks. The first full suite ran 370 tests and found two assertions in one existing options-submenu test: that test assumed Jev was selectable without a key. Its fixture now saves an isolated test key while still leaving the classifier factory nil. This was a requirement-driven test-fixture correction, not a relaxation of disabled-item behavior. The final serial suite passed **370 tests in 49 suites** in 61.599 seconds with exit status 0; `full-tests.log` records the normalized output. Native testing slot released immediately after completion.

## Remaining human acceptance

After explicit installation/trial-launch handover, use the selected branch build and run the submenu's tricky-input check once against each available provider. Save both original report files here (or link their retained evidence), record availability/selected options and tested artifact identity, and distinguish results from the automated fake reports. Enter the Jev key only through the secure alert, never through chat or a tracker comment. No accuracy, real latency, physical focus/destination behavior, or days-of-use result is claimed here.
