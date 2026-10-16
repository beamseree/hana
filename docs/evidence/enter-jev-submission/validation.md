# Enter while Jev is deciding — issue #131

Implemented from Beam's 2026-10-15 request in `codex/enter-jev-decision`, based on `e3ce8dc` from `feature/automatic-switch`. Validation ran on 2026-10-15–16 using Apple Swift 6.3.3 on arm64 macOS 26. The PR targets the existing automatic-switch prototype branch.

## Behavior

With Jev automatic switch enabled, Enter in un-navigated Search without a strong match waits for a full-buffer decision, flushing debounce and correction pauses. Exact pending requests, decisions already waiting for Search, and exact Word-paced cache entries are reused. Earlier-prefix answers cannot switch or save the pending submission. Note/Task decisions must pass the existing threshold, agreement, gate, reversal-veto and multiline rules. The accepted decision enters capture and saves the original raw text once through the existing Capture Session/Store operation.

Edits, composition, result navigation, manual mode selection and dismissal cancel the queued save. Repeated Enter while waiting does not duplicate it. Search/unsure and rejected decisions, failures, backoff, late strong matches and bounded timeouts retain the text and never activate a later result. Strong matches and explicitly navigated results use the normal Search path. The existing 300 ms grace remains for ordinary automatic switches; it does not consume the Enter already committed to this pending save.

## Checks

- `xcrun swift test --no-parallel --filter 'AutomaticSwitch|JevSubmissionNativeTests|SuggestionInteractionTests|JevWordPacedNativeTests'`: **151 tests in 17 suites passed**. This included real AppKit command delivery, fake Jev responses, disposable Store writes, one-save assertions, cancellation, timeout/failure retention, prefix-versus-full-text replies, strong/selected Search activation, existing suggestions and automatic-switch regression checks.
- Subsequent policy-only refinements reuse decisions already waiting for Search, preserve request-timeout diagnostics, and prevent rereading one cached answer from manufacturing a second agreeing verdict. After these refinements, `xcrun swift test --no-parallel --filter 'AutomaticSwitchSubmissionTests|AutomaticSwitchWordCacheTests|AutomaticSwitchWordPacedTests'`: **56 tests in three suites passed**. The preceding broader pure-policy run passed 86 tests in five suites. These counts overlap and are not additive. The native run preceded these final policy refinements.
- Final `./scripts/build`: release compilation, Info.plist validation, ad-hoc signing and strict signature verification passed. An existing `JevKeychainStore.swift` deprecation warning for `kSecUseAuthenticationUIFail` remains outside this change.
- `git diff --check` passed.

Final source SHA-256:

```text
98d341a58872d1bc3d6bf02341522f5c24be3dc882438a5ec405b135c3725ed5  Sources/Hana/AutomaticSwitch.swift
2a56bf88a55b5499a3ddf8aa986b5003b5a0915085c1143d87858b8d37df53bc  Sources/Hana/MacInteraction.swift
27d294b6292a61c2786e17faf274e5e97c1151e4f08575f7b3e060751120c110  build/Hana.app/Contents/MacOS/Hana
```

## Evidence boundaries

Beam explicitly handed over the native testing slot; it was released after the AppKit run. No automated check called the live Jev API. No installed app was replaced or launched during automated verification. These are automated policy, AppKit state and storage assertions, distinct from Beam's installed-build trial below.

## Installed for Beam's trial — 2026-10-16

At Beam's explicit request, the previously running app was quit through its normal termination path. The signed release bundle was copied to `/Users/beamsereeyothin/Applications/Hana.app` and launched with `open`. Strict signature verification passed, the installed executable matched the built executable byte for byte, and the installed-path process was confirmed running. Installed executable SHA-256 is `27d294b6292a61c2786e17faf274e5e97c1151e4f08575f7b3e060751120c110`. The native testing slot was returned to Beam for the trial. No settings or credentials were changed.

Beam subsequently reported **“works”** and requested a PR on 2026-10-16. This records acceptance of the installed Enter flow. It does not establish a broader classifier-quality rate or completion of the separate days-of-use automatic-switch trial.
