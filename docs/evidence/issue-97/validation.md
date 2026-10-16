# Issue #97 — Open a Note capture in its window

2026-10-15, Asia/Bangkok. Comparison base: `2ccd5f7`, with #91's note sessions/windows merged. All Store roots in these checks are marked disposable fixtures. No installed Hana or live collection was changed.

## Delivered behavior

Note capture offers Open in window and Command+Return. Both invoke the same Mac Interaction intent; the panel handles the shortcut even when the origin app owns the menu bar. The standard small native control keeps the text editor's first responder, disables while saving or composing, and appears only in Note mode. The existing card animation constants and deferred bar design remain unchanged.

Capture Session emits a distinct `saveNoteInWindow(operation:body:)` after the same nonblank validation and text freeze as Enter. Search and Task refuse this event. Repeated Open in window/Return triggers issue no additional save. Unchanged retries reuse the creation receipt, including after a lost commit acknowledgment; changing the payload follows the existing new-operation rule. A fresh explicit opening retry resets that attempt's prior dismissal intent while retaining the receipt.

Mac Interaction retains the returned Note ID, transitions out of saving, dismisses with destination semantics and opens the registered note window with its native editor focused at the text's UTF-16 end. It skips the ordinary confirmation/origin restoration for this success target. A failed save keeps the bar's exact text and Note mode editable. Dismissal during an unresolved write preserves the existing late-focus safeguard: the commit may finish, but it does not open a window over the user's later choice.

Note opening also carries focus ownership across its asynchronous session load. A newer capture or destination invalidates the request. A change to a different foreign frontmost app suppresses opening; Hana's own activation transition is allowed. The note uses the same explicit `activate(from:source, options:[])` request as the main window. An activation acknowledgment is not physical focus proof.

## Automated checks

`red-tdd.txt` captures the new session event/effect, Mac Interaction intent and control failing compilation before implementation, plus the real failing composition-control assertion before its fix. `focused-tests.txt` records **50 tests across eight suites passing in 8.776 seconds**, covering OpenNoteCapture, existing Capture Submission/Safety, Note/Task saves and native note windows.

New fixture checks cover exact Thai/emoji/Markdown text; one paused transaction under repeated intents/Return; native note editor responder and literal UTF-16 end offset 15; blank/non-Note refusal; unchanged receipt retry; both precommit failure and lost acknowledgment; control action and Command+Return routing; composition refusal/control disabling; dismissal during a committed write; and a delayed collection opening that cannot take focus from a newer capture.

Two intermediate combined runs exited with code 0 without a final test summary because test teardown called the asynchronous note-close path through `stop()`. They are not counted as passes. Fixtures now close registered windows synchronously after closing the Store, leaving no async close work outside the native slot. The full focused run above completes with a summary. A first broader run also caught the new opening guard refusing Hana's own pending activation after main-window opening; permitting that owned activation transition fixed the existing NoteWindowTests.

## Native app-loop verification

The fixture-only `--validate-open-note-capture --open-note-capture-report PATH` route runs before normal live collection opening. It creates a new marked root, uses the real NSApplication event loop, and removes that root before quitting its own process. It verifies native button click and Command+Return, blank refusal without editor focus loss, repeated triggers during a paused write, one committed note and key window/editor at offset 15, precommit and lost-ack retry producing one note each, and dismissal during a paused commit keeping the newly chosen main-window focus with no late note window.

`native-runtime.jsonl` records the passing signed debug fixture run. Tested binary SHA-256: `d4a93428a37d71fc179712c63f65dd1a2359fc809a577ed4a4d01ecbb4f3a932`. Test compilation uses Apple Swift 6.3.3 on macOS 26.5.1 with explicit CLT Testing/TestingInterop search paths. Every native test/app process uses the atomic `/tmp/hana-spec-88-native-lock`; no simultaneous native processes are counted as evidence. The validation bundle is isolated at `/tmp/hana-97-native/Hana-Issue97.app`, with identifier `com.beamseree.hana.validation.issue97`.

## Limits

The native trace establishes automated AppKit key-window/responder state, not Beam's physical keyboard input, foreign-app full-screen routing, VoiceOver speech, Thai candidate-input experience or final visual approval. Those remain #99 observations. Existing backup/restore deferrals and forced-kill limits remain unchanged. No issue closure, installation, push or PR action is performed by this slice.
