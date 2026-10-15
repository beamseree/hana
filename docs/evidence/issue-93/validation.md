# Open-note organization — #93

2026-10-15, macOS 26.5.1 (25F80), Apple Swift 6.3.3 / CommandLineTools, arm64. Integration comparison: `4c05ae8`, including #92 lifecycle safety, #97 capture opening and #98 preview. Both agreed seams use real disposable fixture Stores; the live collection is never opened.

## Behavior

All main-window note intents, including row context menus and native Note menu commands, use Mac Interaction's session-aware route. An existing Note Editing session freezes input before flushing, then submits Pin/Unpin, Archive or Restore with its current committed revision. It remains frozen through the metadata acknowledgment. A failed flush prevents the metadata command and preserves the writing and typed save failure. Composition is refused with an explanation until the user finishes it. Independent organization, close and quit freeze reasons cannot release each other.

Archive leaves the native note editor read-only with a Restore button. The button and the Note menu expose Control+Command+R; Pin/Unpin and Archive retain Control+Command+P/A. Restore preserves source, pin and content-edited time, returns the committed note to Notes and enables writing. A metadata-only observation adopts the new revision without replacing pending source; peer Restore also returns a read-only session's save state to Saved. Late metadata acknowledgment cannot revive a closed or invalidated session, and invalidation status takes priority over the organization progress message.

## Automated checks

`focused-tests.txt`: 50 tests in 12 suites passed in 14.027 seconds. This includes Note Editing, both open-note organization suites, existing note save safety/native lifecycle, main Notes, native note editor, Markdown preview, capture opening and task ordering. Native processes acquired the shared atomic lock and used the external CLT Testing/Interop wrapper with scratch directory `/tmp/hana-spec-88-build-90`.

The organization checks cover pending native source committed before Pin; the next autosave using the adopted revision; peer metadata adoption and Restore; dirty native archive with typing attempted during its paused metadata transaction; read-only typing refusal and native Restore; failed flush leaving the note unarchived with Retry/Copy visible; marked Thai composition refusing organization without a half-composed save; independent quit suspension; and a committed metadata acknowledgment released after Store close/reopen preserving terminal invalidation.

`red-tdd.txt` records actual failures before their fixes: direct main-window metadata skipped pending editor source; peer Restore retained read-only save state; a paused archive showed Saved instead of progress; and progress masked invalidation while an acknowledgment was held. Earlier API compilation failures are retained in the external task context but are not needed to establish these behavioral failures.

`native-runtime.jsonl`: the existing signed fixture application's real run loop reached `note-window.organization` and `note-window.validation-passed`, then exited with status 0. Synthesized Control+Command key equivalents invoked the real native Note menu for Pin, Archive and Restore. The run verified the body flush, read-only refusal, restored metadata, minimized/raised singleton behavior, Escape focus, committed titles/Window menus and held last-window close. `build.txt` and `sign.txt` record the build and signature verification. Executable SHA-256: `e3ea495de4c44f0f7190bfd27c6f8e97486abf9ba7df7a2c59f9eaa3c55a5858`.

## Limits

These are automated AppKit events and fixture observations. Physical keyboard, input-method interaction, full-screen Space routing, rendered visual polish and integrated quit/relaunch acceptance remain #99. No screenshot or physical acceptance is claimed. The existing app-loop harness was extended; no new broad harness or persistence schema was introduced.

Post-merge primary integration `87599d6`: `integration-tests.txt` records a fresh-scratch run of 24 tests in 5 suites passing in 7.601 seconds, covering both organization seams, main Notes and both save-safety suites.
