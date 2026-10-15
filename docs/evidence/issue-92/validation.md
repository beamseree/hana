# Note save safety — #92

Environment: macOS 26.5.1 (25F80), Apple Swift 6.3.3 / CommandLineTools, arm64. Tests use the two agreed seams with marked disposable fixture Stores, never the live collection. Native processes coordinate the atomic `/tmp/hana-spec-88-native-lock` directory and use the CLT Testing/TestingInterop framework flags in the external test wrapper.

## Behavior and checks

- `NoteSaveSafetyTests.failureKeepsLatestTextAndRetryCommitsItOnce`: a typed disk-full fault preserves source and failure status. Editing after failure retains the reason; Retry submits the current text. Revision 2 contains the latest bytes once.
- `aLostAcknowledgmentCanRetryWithoutASecondEditOrStaleRevision`: a fault after the real commit preserves the source and typed I/O reason. Reading back identical submitted bytes reconciles the committed revision; repeated Retry acknowledges that body without another edit/revision.
- `closingTheStoreInvalidatesAPausedSaveBeforeItCanCommit`: a real write is paused before commit, Store close invalidates the session, and the released transaction rolls back. A newly opened Store retains the original body; old typing and dirty flushes are refused.
- `closingFreezesEditsBeforeSuspendingAndRestoresOnlyItsOwnFreeze`: closing blocks edits before awaiting its save. A failed close restores editability while preserving a separate quit suspension; a successful close retains the submitted source.
- `explicitDiscardRollsBackAPausedUncommittedSave`: Discard cancels the session's write task. The Store checks cancellation at its transaction boundary, so the paused uncommitted edit rolls back. Already committed collection state is retained.
- `NoteSaveSafetyNativeTests` uses the actual native editor, status row, sheets, first responders and pasteboard. It checks Retry/Copy Text with exact retained text; failed-close Retry versus explicit Discard; pending-close choices and cancellation; invalidated non-editability/copy/quit refusal; quit failure and success across two notes including marked Thai text; and a paused quit refusing late native/direct edits, new note windows and bar invocations.
- Existing captures already submitted when Quit starts are awaited. A failed in-flight capture cancels quit and keeps its text in the bar; retry saves it once. The bar check drives its visible native window's first responder: the CLT helper cannot reliably establish global key focus for a regular application. Physical focus is an app-loop/#99 observation, not inferred from this check.
- Session flush during composition throws instead of reporting success. Native lifecycle adapters commit marked text before flushing. Invalidated dirty sessions also refuse flush/quit until the user explicitly discards; clean invalidated sessions can close.

## Red evidence

`close-race-red.txt` reproduces six late-edit/closing failures before the independent close freeze. `invalidation-red.txt` and `discard-red.txt` show the original body being replaced by an obsolete paused commit. `quit-race-red.txt` shows seven real failures: editing stayed enabled, late source was accepted after its earlier flush, openings were allowed, and the reopened Store lacked the final text. The implementation rechecks Store generation and cancellation before commit, freezes sessions and native input before the first quit suspension, blocks openings, and restores editing after a failed quit.

## Limits

Forced process termination can still lose uncommitted edits in the autosave window. This slice provides orderly lifecycle safety and explicit retained-source choices; automatic backup/restore remains deferred. All UI actions above are automated fixture events. Beam's physical IME, full-screen, focus, long-note responsiveness and quit/relaunch observations remain #99.


## Recorded results

- `regression-tests.txt`: 44 tests in 8 suites passed in 7.673 seconds. This covers the new safety suites, prior Note Editing/native note editor checks, Store foundation/organization, main Notes and capture saving rules.
- The Store's previous queued-close check assumed the first held transaction could commit after close. Its expectation is updated to the stronger invalidation rule, and both rolled-back creation operation IDs are proven retryable without leftover receipts.
- A concurrent-composition regression also showed that a caller awaiting a completed save task could return success without rechecking newly composing text. Save-task cleanup now occurs inside the operation, and waiters revalidate the current lifecycle state after awaiting it.

- `merged-tests.txt`: after integrating capture-to-window and Markdown preview, 51 tests in 12 suites passed in 13.363 seconds. This includes the independent close freeze test, previous note safety checks, capture opening/focus ownership, preview stale-render/parser checks, native main Notes and Task ordering.
- `native-runtime.jsonl`: the signed fixture app's real run loop reached `note-window.validation-passed` and exited normally with status 0. The last note stayed registered with regular activation policy while its save was paused, committed exact text before closing, and changed to accessory policy afterward. It also verified minimize/raise, Escape focus and one native Window-menu entry.
- `build.txt`: the merged debug application built successfully. The async validation helpers now schedule their final Quit on the main run loop, allowing their Swift task and main dispatch callback to return before AppKit waits for deferred termination. Direct calls from a Swift task and raw main-queue callbacks both reproduced a nested-loop deadlock; these incomplete runs were stopped and are not passes. The native production Quit selector remains unchanged.
- `main-runtime.jsonl` and `capture-runtime.jsonl`: the signed main-window and capture-to-window fixture app loops also reached their validation-passed events and exited normally with status 0 after the termination scheduling correction.
- `integration-tests.txt`: the fresh-scratch post-merge primary integration run passed 34 tests in 7 suites in 7.388 seconds, covering safety/native safety, Store, editing, preview and capture-to-window.
