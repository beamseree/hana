# Task-focused Jev — local trial

Requested by Beam on 2026-10-16: keep automatic switching task-focused, explicitly include information, ideas and ambiguous text in Other, then install for a human trial.

Jev continues to offer Search, Task and Other. Other now reads:

> Information, observations, ideas, incomplete or ambiguous text, or anything that is not clearly a search or a new task

Other maps to unsure and leaves the text in Search. The Search and Task criteria are unchanged. Explicit Note capture and Foundation Models' original Note/Other wording remain available.

The wording/cache token is `jev-task-focused-v1`. Both the original four-choice cache and the preceding `jev-without-note-v1` cache are isolated from the new wording. Historical diagnostic tokens remain decodable.

## Automated verification

- **155 selected non-native tests in 18 suites passed**, with no test skips. No live Jev calls were made.
- Request payload assertions check the three choice keys and the exact Other wording. Cache regression coverage checks that neither an original Note verdict nor a preceding-trial Task verdict can satisfy the new wording. Error/timeout/backoff diagnostics use the current trial token.
- `git diff --check`: passed.
- Automated native window tests remain pending at Beam's earlier request. The intended meaning of Other is covered by the request text and mapping; Beam's overall installed-build acceptance is recorded below, without a measured model-accuracy claim.

Command:

```sh
xcrun swift test --no-parallel --filter 'ClassifierAdapterTests|JevHTTPSessionTests|TrickyInputCheckTests|AutomaticSwitchDebugTests|JevRequestActivityTests|JevSharedTransportTests|AutomaticSwitchTests|AutomaticSwitchWordPacedTests|AutomaticSwitchWordCacheTests|AutomaticSwitchDeletionTests|AutomaticSwitchWithdrawalTests|AutomaticSwitchReversalOptionsTests|AutomaticSwitchSubmissionTests|AutomaticSwitchReviewPolicyTests|AutomaticSwitchWakeUpTests|AutomaticSwitchSessionCountTests|AutomaticSwitchDiagnosticsTests|AutomaticSwitchWithdrawalDiagnosticsTests'
```

Raw output: [tests.log](tests.log).

This change follows the debug-footer work in merged PR #137. The installed task-focused build was accepted by Beam before publication.

## Installed trial

Signed release build, strict signature verification, installation and relaunch passed via `./scripts/run`. Built and installed executables match. The persistent signing identity is unchanged.

- Installed app: `/Users/beamsereeyothin/Applications/Hana.app`.
- Verified running PID: `71786`.
- Executable SHA-256: `8509abc6ba222afbd32e4c0a7f460e685a57e532c6f66d5e491963f47aea7a94`.
- Previous installed app retained at the temporary backup path in [install-result.json](install-result.json).
- Native installation slot released; the running app is handed back to Beam for testing. No native test suite, live inference checks or permission changes were performed.
- Raw evidence: [release-build.log](release-build.log), [install.log](install.log), [install-result.json](install-result.json).

## Human acceptance

On 2026-10-16, after testing the installed task-focused build above, Beam said **"looks good"** and requested that the task-focused changes be pushed and the PR updated. PR #137 had already merged, so publication uses a follow-up PR against `main`. This records overall acceptance of executable `8509abc6ba222afbd32e4c0a7f460e685a57e532c6f66d5e491963f47aea7a94`; it does not establish measured classification accuracy or individually verified native focus/timing cases. Automated native tests remain intentionally pending.
