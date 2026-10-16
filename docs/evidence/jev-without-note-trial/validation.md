# Jev without Note choice — local trial

Requested by Beam on 2026-10-16: remove `"Note": "Capture a thought or information as a new note"` from the Jev request choices.

The local Jev request now offers only Search, Task and Other. Its response validator requires exactly those probability keys, and Other still maps to unsure. Foundation Models retains its Note option and the existing wording version. Explicit Note capture remains available.

Jev's wording token and launch-cache identity are `jev-without-note-v1`. An old four-choice response is rejected, and a cached Note answer from the prior wording cannot satisfy a request in this trial. The tricky-input report and verdict/error/backoff diagnostics identify the Jev trial version.

## Verification

- **155 selected non-native tests in 18 suites passed**, including the Jev adapter, retained HTTP session, tricky-input report, automatic-switch policy/cache and debug-footer regressions. No live Jev calls were made.
- Added request-choice and response validation assertions, a regression proving that prior-wording Note cache entries cannot switch the bar during this trial, and error/timeout/backoff checks for the trial wording token.
- `git diff --check`: passed.
- Automated native window tests remain pending at Beam's earlier request. Live model behavior is for Beam's trial; deterministic fixtures do not establish classification quality.

Command:

```sh
xcrun swift test --no-parallel --filter 'ClassifierAdapterTests|JevHTTPSessionTests|TrickyInputCheckTests|AutomaticSwitchDebugTests|JevRequestActivityTests|JevSharedTransportTests|AutomaticSwitchTests|AutomaticSwitchWordPacedTests|AutomaticSwitchWordCacheTests|AutomaticSwitchDeletionTests|AutomaticSwitchWithdrawalTests|AutomaticSwitchReversalOptionsTests|AutomaticSwitchSubmissionTests|AutomaticSwitchReviewPolicyTests|AutomaticSwitchWakeUpTests|AutomaticSwitchSessionCountTests|AutomaticSwitchDiagnosticsTests|AutomaticSwitchWithdrawalDiagnosticsTests'
```

Raw output: [tests.log](tests.log).

This initial experiment followed the debug-footer change in PR #137. It was superseded by the [accepted task-focused Other wording](../jev-task-focused-trial/validation.md); the evidence here identifies the earlier installed artifact.

## Installed trial

Release build, strict signing verification, installation and relaunch passed via `./scripts/run`. Built and installed executables match.

- Installed app: `/Users/beamsereeyothin/Applications/Hana.app`.
- Verified running PID: `50868`.
- Executable SHA-256: `5f67f6fb43ddbab0d6e2f11664788277034c83f70f1cad9ecbde3b6cf48ee8bf`.
- Previous app bundle retained at the temporary backup path in [install-result.json](install-result.json).
- Native installation slot was released. No native tests or live model quality checks were performed.
- Raw build/install evidence: [install.log](install.log), [install-result.json](install-result.json).
