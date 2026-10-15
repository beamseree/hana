# Note Editing and native note windows — #91

Observed environment: macOS 26.5.1 (25F80), Apple Swift 6.3.3, arm64, CommandLineTools. Full Xcode/Instruments is unavailable. All data uses marked disposable fixture collections; no test intentionally opens the live collection.

## Automated session checks

`NoteEditingTests` uses the agreed Note Editing seam, TestClock and real temporary Stores. It checks the 299/300 ms idle boundary and exact Thai, decomposed Unicode and Markdown bytes after Store reopen; continuous edits saving by 1 s; composition preventing submission; a paused writer draining newer text in revision order; and blank-close preserving the saved body with the required explanation. The first focused test passed before the additional slices. The initial red attempt also exposed the CLT's nondefault Testing framework location; subsequent runs add framework and TestingInterop runtime search paths explicitly, without changing the product package.

## Native checks

`NoteWindowTests` drives Mac Interaction and the real first-responder NSTextView. It checks singleton window identity, TextKit 2, typed punctuation, Return newline, native undo/redo, marked text and paste, followed by an explicit flush. Committed title/list/menu updates, deactivation flush, minimize and asynchronous close run in the app-loop harness. Tests use the coordinated native slot; separate processes use an atomic `/tmp/hana-spec-88-native-lock` directory.

The CLT async Swift Testing runner exited with code 0 before its test summary when a minimized/last-close path drained its main queue. An LLDB exit breakpoint showed `_swift_exit` from `swift_task_asyncMainDrainQueue`, not a successful test completion. Those incomplete runs are not counted as passes. The fixture-only `--validate-note-window --note-window-report PATH` harness uses the app's actual NSApplication run loop for minimize/raise, Escape focus restoration and a held final-window flush retaining regular activation policy until commit, followed by accessory policy.

## Long-note fixture

The native test creates a Markdown/Thai source document larger than 1 MB and records open-to-first-responder, one native insertion and flush wall durations. These are one debug fixture run, including AppKit/layout/Store overhead as applicable. They are a profiling fixture rather than a maximum size, Instruments trace, or physical typing/scrolling claim. No concurrency offload is inferred from these measurements.

## Physical observations still required

Beam's physical Thai/IME typing, long-note typing/scrolling, Dock and Command-Tab, native full-screen invocation and edits across app quit/relaunch remain #99 observations. Automated events do not establish those results. Automatic backups/restore remain deferred, and a forced process kill can lose uncommitted edits.


## Recorded results

- `focused-tests.txt`: 6 tests in 2 suites passed in 1.798 seconds, including the 1.14 MB fixture.
- `native-runtime.jsonl`: signed disposable release app reached `note-window.validation-passed`. It recorded regular policy while minimized and while the last window's commit was paused, exact saved text and accessory policy after close, Escape responder restoration, and one native Window-menu entry after the committed title changed.
- Debug fixture (1,140,000 UTF-8 bytes): open 267.643 ms, one insertion 317.437 ms, flush 639.191 ms. Debug iteration overhead is material; release measurements are recorded separately before drawing performance conclusions.

- `release-profile-before.txt`: the pre-optimization release fixture passed, measuring open 236.479 ms, insertion 163.634 ms and flush 252.491 ms.
- `release-tests.txt`: after bounded optimization, 19 tests in 4 suites passed in 1.794 seconds. The 1.14 MB fixture measured open 98.747 ms, insertion 70.416 ms and flush 106.902 ms. Title extraction now stops at the first nonempty line rather than splitting the full document; normal text insertions report one edit, and view updates use the local text revision instead of rescanning all bytes. No concurrency was introduced. A 70 ms synthetic insertion is still not a guarantee of smooth physical typing or scrolling, which remains a #99 observation.
- The paused-writer test now holds both the first and second save transactions: after the older commit, the public session remains `saving` with the latest text, while the Store still contains the first body until the second gate is released.

- `integration-tests.txt`: the post-merge release run passed 16 tests in 4 suites (Note Editing, native note editor/profile, Task Workspace and Main Window) in 4.029 seconds.

- `final-merge-tests.txt`: after merging #95 as well, 10 debug tests in 3 suites passed in 3.154 seconds, including task keyboard/drag/stale-order checks. The optimized debug fixture measured open 98.996 ms, insertion 147.597 ms and flush 320.375 ms.
