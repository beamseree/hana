# Read-only native exit diagnosis

Inspected source `924766b4c3881d84e9223790212d1e4615330224` in `/Users/beamsereeyothin/.codex/worktrees/issue-141-calculator-numeric-fixes/hana`. No native launches, test processes, repository edits, app control, settings changes, or GitHub mutations were performed by this agent.

## Observed evidence

- `34-full-tests.log` stops after the `.retry` case of `NoteSaveSafetyNativeTests.failedCloseIsHeldUntilRetryOrExplicitDiscard` starts. `34-full-test-result.json` records exit 0 but no final suite summary. `35-isolated-note-save-fixtures.log` independently stops at the same case. Neither is a passing full-suite result.
- `36-fixture-exit-debugger.log` did not reach the test: debugger attachment was denied. `37-fixture-exit-trace.log` is a direct Mach-O bundle launch error; the observed `38-fixture-exit-trace.log` contains a Testing.framework dlopen error. These instrumentation failures do not diagnose the original exit.
- An earlier local full run, `08-full-tests.log`, ends with **644 tests / 93 suites passed**. `git diff --stat a0ce847 HEAD -- Tests/HanaTests/NoteSaveSafetyNativeTests.swift Tests/HanaTests/CompletedArchiveTests.swift Tests/HanaTests/NativeAppFixture.swift Sources/Hana/NoteWindowController.swift Sources/Hana/MacInteraction.swift` is empty: this native path was unchanged between that earlier source and the pinned source. This is supporting context, not final-source validation.

## Existing measured mechanism

- `Tests/HanaTests/CompletedArchiveTests.swift:218-220` deliberately uses `interaction.windowShouldClose(window)` instead of `window.performClose(nil)`, explaining: "Actual performClose is covered by the app-loop harness; CLT can drain its main runner there."
- `Tests/HanaTests/NativeAppFixture.swift:6-9` documents async-main test host activation/event dispatch draining the queue before a summary.
- `docs/evidence/issue-88/native-context-corrections/validation.md:19-30` records the same exit-0/no-summary symptom and an actual LLDB observation. Its `readiness-exit-stack.txt` shows:
  `_swift_exit` -> `swift_task_asyncMainDrainQueue` -> generated test `Runner.main` -> `swiftpm-testing-helper`, with **no NSApplication termination frame**.
- The current generated `.build/arm64-apple-macosx/debug/HanaPackageTests.derived/runner.swift:506-546` is an async `Runner.main` that awaits `Testing.__swiftPMEntryPoint() as Never`. The async-main host is therefore still the relevant host.
- The existing mitigation for the two earlier affected tests is an actual signed NSApplication child through `NativeAppFixture`, requiring a specific assertion marker, entire validator success marker, normal exit, and a complete parent test summary. No product activation workaround was added.

## Current trigger boundaries and ranked predictions

1. **Most supported: async-main host drains while native `performClose` presents the failure sheet.** Current test line 63 calls actual `window.performClose(nil)` after a stored failure. It reaches `NoteWindowController.shouldClose` at lines 212-219, which synchronously calls `showCloseChoices`; line 268 begins an NSAlert sheet. The earlier CompletedArchive comment is a direct precedent for this precise native-close API in this host. Prediction: a last-boundary marker after test line 63 is absent, and the exit stack matches the earlier runtime stack rather than `NSApplication.terminate`.
2. **Same host mechanism later, while ending the sheet after retry.** Test line 73 awaits `.retry`; controller lines 127-134 call `closeSession`, whose lines 242-247 close the session, end the sheet and close the window. `dismissCloseSheet` line 287 invokes native `endSheet`. Existing issue-88 note-focus JSONL traces show this exact `dismissCloseSheet` -> `NSWindowEndWindowModalSession` -> NSAlert/AppKit window-ordering/key path. Prediction: line 63 and held-sheet/copy assertions complete, but no marker after retry returns; exit stack is still host drain.
3. **Less supported: explicit application termination.** The searched native test/controller paths do not call `exit` or `NSApp.terminate`; production quit at `MacInteraction.swift:1031` and validator termination paths are elsewhere. Prediction: a successful exit trace contains `-[NSApplication terminate:]` / application delegate termination frames instead of the prior runner-only stack. A trace with the prior `_swift_exit` stack weakens this hypothesis.

The existing logs do not distinguish presenting the sheet from ending it, so no precise current trigger or product defect is claimed.

## Focused next observation

The native-slot owner's outside-repository `atexit` helper is the right next observation once the owned `swiftpm-testing-helper` has the same Testing.framework lookup environment as the normal SwiftPM invocation. Compare the exit stack to `readiness-exit-stack.txt`. If it identifies only the runner drain, capture the last completed boundary around **native `performClose` returning**, **held sheet observed**, and **retry returning**, without changing any assertion or production behavior. The smallest useful decision is whether the already-known native-close/async-main host limitation is being reached again. Do not rerun the full suite until the narrow run has a complete final summary.
