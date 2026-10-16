# Interim native regression diagnosis

2026-10-15, Asia/Bangkok. Read `diagnosing-bugs` skill and used unchanged test assertions as the differential feedback loop. No source/test edits, instrumentation, dependency changes or product fix were made. The already-committed #97 branch was preserved. Every test process held `/tmp/hana-spec-88-native-lock` and used `/tmp/hana-spec-88/test`; own scratch `/tmp/hana-spec-88-build-90`.

## Outcome

**The original 30 issues did not reproduce in any new probe.** Full unchanged baseline and full unchanged current integration both passed with complete Swift Testing summaries. No product regression or root cause is established. External UI activity is currently the strongest explanation, but the original failed run lacks content-free dismissal state, so it remains a hypothesis rather than a claimed diagnosis/fix.

| Source / scope | Result | Log under `/tmp/hana-spec-88/` |
| --- | --- | --- |
| Original parent run, `cb906c7`, full | 344 tests / 47 suites, 30 issues, 125.448 s | `interim-full-tests.txt` |
| `cb906c7`, exact Search-height + Note-growth tests | 2 tests / 2 suites passed, 0.547 s | `regression-current-height-1.txt` |
| `cb906c7`, exact paused-save focus test | 1 test / 6 parameter cases passed, 1.536 s | `regression-current-focus-1.txt` |
| `ced5e5f`, same three exact symptom tests | 3 tests / 3 suites passed, 1.993 s | `regression-baseline-minimal.txt` |
| `cb906c7`, complete suspect suites | 44 tests / 5 suites passed, 12.267 s | `regression-current-suspect-suites.txt` |
| **`ced5e5f`, full baseline in quiet slot** | **314 tests / 40 suites passed, 51.634 s** | `regression-baseline-full-quiet.txt` |
| **`cb906c7`, full current in quiet slot** | **344 tests / 47 suites passed, 57.852 s** | `regression-current-full-quiet.txt` |

The suspect-suite filter is `CaptureSafetyNativeTests|MacInteractionTests|NoteModeTests` (Swift Testing also includes matching nested suites). The exact symptom filter is `noteGrowsDownwardToAMaximumHeightAndThenScrolls|loadingUsesNoStatusRowAndNoResultsWaitsForBothSources|dismissalDuringAPausedSavePreservesTheOutcomeAndTheChosenFocus`. Full command: `/tmp/hana-spec-88/test --scratch-path /tmp/hana-spec-88-build-90 --no-parallel`, surrounded by the atomic directory-lock loop and EXIT release trap. Each git state was checked out detached in the clean ticket worktree; no uncommitted code was compared.

## Ranked hypotheses and falsifiable predictions

The first four were sent to the parent before new probes; the fifth came from the parent's observation about the active desktop/user slot.

1. **Baseline CLT/AppKit animation scheduling limitation.** Prediction: unchanged isolated height probes fail both revisions, while an app-loop harness grows correctly. Both isolated and full runs passed, so an unconditional version of this hypothesis is unsupported. A transient scheduler problem cannot be ruled out by passing samples.
2. **Process/order-dependent native focus contamination.** Prediction: isolated cases pass but a particular larger test order reproduces missing key state. The complete suspect suites and full current run both passed, so no load-bearing order has been identified.
3. **#97 trailing-control/layout regression.** Prediction: current isolated Note growth fails while baseline passes, possibly with Search unaffected. Both exact height probes and both full revisions passed; no evidence supports this regression.
4. **#91 asynchronous note-window teardown escaping its slot.** Prediction: failures require preceding note-window tests and disappear with synchronous fixture closure. #97 already fixed its own asynchronous teardown before `cb906c7`; the original full run's paused-save failures begin in its *first* native suite, before NoteWindowTests. This cannot explain all 30 original issues. Existing combined #97 and current full-suite passes also provide no new teardown repro.
5. **External physical mouse/app/Space activity dismissing real fixture panels.** Prediction: failed state has `currentInvocation == nil`, hidden Search panel, reset Search mode and collapsed height; a quiet slot passes unchanged. The quiet full current run did pass. This is consistent with the original symptoms, but the original log does not contain the needed state, and quieting the desktop was not the only difference from the original execution, so causation is unproven.

The skill's reproduce/minimize stage cannot be completed while every new exact/minimized/original-command run is green. No speculative product fix or fabricated failing test was written.

## Why external dismissal fits the signature

At `cb906c7`, `MacInteraction.observeSession` (line 717) installs actual local/global mouse monitors, workspace activation/Space/sleep observers and display-change observers. `appChanged`/`environmentChanged` call the real dismissal path. `dismiss` (line 318) normally clears the invocation, orders the panel out, resets Capture Session/editor/Search and renders the collapsed bar. Thus a legitimately externally dismissed test surface can present both `NSApp.keyWindow == nil` and the observed collapsed height **68**, even though a test's later feed/edit assertions keep running. This is a source-based explanation of the symptom shape, not evidence that a particular external event happened in the original run.

`NativeWindowSlot` serializes test suites inside one process; the external directory lock serializes agent-native processes. Neither prevents a human from clicking another application, invoking the already-running installed Hana, changing Spaces or altering screen state. The installed Hana process was left running throughout these checks. No monitor was suppressed or global input intercepted to make tests green.

## Runner improvements and next-failure capture

- Keep native runs in an explicitly announced quiet keyboard/mouse/Space slot; preserve the process/suite locks. The parent issued that notice before the two full passing differential runs and was told when the slot ended.
- Add **test-only, failure-only context** to the exact native helper/assertion sites: whether the expected invocation still matches, mode/phase, panel visibility/key status, content/frame height, NSApp activation policy, whether the expected first responder still belongs to the fixture window, and the last typed dismissal reason. Do not log text, titles, paths, key values or foreign document details. This should accompany the existing assertions rather than replace/relax them.
- Reuse injected `Diagnostics(file:)` for suspect fixture instances or add a bounded test diagnostic sink; retain the original production mouse/app/Space observers. A temporary probe, if needed, should log only the `dismiss`/`setPanelFrame` boundary with a unique `[DEBUG-native-regression]` prefix, then be removed after reproducing. No such probe was needed or left behind in this run.
- If a future failure reports a live matching invocation and visible panel with height 68, animation/layout becomes a concrete separate lead. If it reports a cleared invocation/hidden panel, inspect the dismissal trace and external event first. If a clicked key panel itself never becomes key, record that before relying on later capture assertions.
- Maintain synchronous registered-window cleanup inside native fixture scopes, after needed session flush/Store close; keep real async close/quit lifecycle checks in app-loop validation. This preserves the already-fixed #97 teardown rather than reopening it as an explanation for the unrelated original first-suite failures.

## Correct app-loop coverage to retain/extend

Use a separate fixture-only signed app identity and real `NSApplication.run`; never the installed/live Hana identity or collection. Existing `--validate-main-window`, `--validate-note-window` and `--validate-open-note-capture` harnesses already cover committed capture/list updates, native focus/end selection, note singleton/activation/close and Open in window's paused/failure/lost-ack/dismissal behavior.

For #99, extend the app-loop matrix to the older paused capture path too: Note and Task × committed/rolled-back/lost acknowledgment × Escape/outside choice, with another owned destination genuinely becoming key; assert one committed record, preserved failed text, no late focus theft, and explicit reinvocation/retry. Include the old Search 188-point suggestion/loading geometry and Note newline/max-height/scroll/return-to-Search geometry under the app loop, with content-free frame/visibility/invocation traces. The runner assertions remain useful and unchanged; these app-loop checks distinguish AppKit scheduling/focus from physical human observations. Physical full-screen/Thai/keyboard/VoiceOver claims still require their separate #99 evidence.
