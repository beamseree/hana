Read-only Spec/native-context review of ee5471a5351b22f6313cd80f64269b57b98650bc against a17608f. No edits/native processes.

One small assertion-relocation gap remains:

- **Preserve the original intermediate capture-dismissal assertion.** Removed `OpenNoteCaptureTests.aNewerInvocationKeepsFocusWhenAnEarlierNoteOpeningFinishes` captured `originalEditor` and awaited `originalEditor.window?.isVisible == false` after the invocation-bound note open, before opening the newer bar. `Sources/Hana/OpenNoteCaptureValidation.swift:118–122` discards that editor, waits only for the deferred collection continuation, then presents the next invocation. The final current-invocation/key-responder/query/no-note assertions are preserved, but they can pass even if the earlier bar never hid. Retain the original editor and assert its window is hidden before the newer invocation. This is a test-coverage gap, not an established product defect.

Otherwise the relocation is semantically sound:

- MainWindowValidation preserves every original menu assertion: no-selection disabling, selected enablement, Pin/Archive key equivalents/modifiers, Pin, Unpin title, Unpin, Archive removing the only row and post-archive disabling. Its marker follows those assertions; restoring the seed afterward supports the remaining validator checks.
- Capture validation uses a real invocation token and actual NSApplication key-window/first-responder/query checks, without a fake local-focus replacement.
- NativeAppFixture fails on missing executable, signing/child failure, timeout, missing targeted marker, missing complete-validator marker or any validation-failed event. A fresh report root prevents stale-marker reuse. Both original Swift Test names remain active, and completion requires child exit0 plus behavioral evidence; helper early exit is not accepted as success.
- The minimized-window production change retains explicit activation, nonminimized raising, registry/policy behavior and note responder/end-offset setup while allowing AppKit to complete deminiaturization before native key acknowledgment.

The reported two-test complete result and uninstrumented NoteWindow validator evidence support the bounded change. Final merged suite/release identity and Beam's physical acceptance remain separate gates.

Follow-up verification — f7a7c79d7573df5892fb8cd9f41ce2b50b607fc6 against ee5471a:

Resolved. OpenNoteCaptureValidation now retains originalEditor and awaits its window's exact isVisible == false condition after the invocation-bound open and before waiting for the collection continuation/presenting the newer invocation. The final invocation/key-responder/query/no-window guards and success markers are unchanged. No remaining actionable defects identified in the targeted assertion-relocation/native-context scope.

The adapter's added failed-event print leaves failure outcomes and completion requirements intact. Evidence retains the initial combined child-exit1 failure with unknown step, the isolated capture pass, and the final complete 2-test/2-suite pass in6.249s; no cause is invented for the initial failure. This verification was read-only source/evidence inspection, with no native rerun.
