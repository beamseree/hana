# Issue #90 — Pin and archive from Notes

2026-10-15, Asia/Bangkok. Comparison base: `ced5e5f` (merged #89).

## Delivered behavior

Notes rows carry their last observed Store revision. Mac Interaction exposes `organizeNote(row, action:)` and selection; the native Note menu offers Pin/Unpin Note (Control+Command+P) and Archive Note (Control+Command+A). Each row offers the same actions in its context menu. Menu validation disables these commands without a selected active Notes row, while another note action is running, or while the capture bar has an invocation. The pin command follows the selected row's current pin state. Archiving clears a disappearing selection.

The controller submits `setNotePinned` and `archiveNote` using the row's expected revision and the current Store generation. It does not reorder or remove rows optimistically: the existing `.notes` observation supplies every displayed committed value. Pinning therefore preserves content-edited order, and unpinning returns the note to that position. Typed refusals are retained in presentation and displayed with a short explanation. A concurrent edit is observed normally, and a stale action cannot overwrite it or archive it.

## Automated evidence

The agreed Mac Interaction seam uses real disposable fixture Stores and the native window slot. `red-tdd.txt` records failing compilation for each new public capability before its implementation: pin, archive, refusal presentation and menu selection. The first toolchain attempt also encountered a missing Testing module; explicit local framework and runtime paths resolved this without changing the project or toolchain.

`focused-tests.txt` records the passing focused Notes organization and existing main-window regression run: eight tests across two suites (ten executions including parameter cases), 2.905 seconds. `MainNoteOrganizationTests` checks:

- Pin moves an older note above a newer note; Unpin restores the prior committed order; both preserve `contentEditedAt` through the Store interface.
- Archive removes the row and preserves exact Thai/Markdown text, pin and content-edited time.
- Both a stale pin and a stale archive report `staleRevision`, display the concurrently committed title and leave the committed record unchanged.
- Native menu actions operate on selection for Pin, Unpin and Archive; the pin title updates; both shortcuts carry Control+Command modifiers; absent/disappeared selection disables actions.

All native test processes acquire `/tmp/hana-spec-88-native-lock` atomically and release it after exit. The scratch build is `/tmp/hana-spec-88-build-90`. Tests never open the live collection. Local test commands use the Testing framework at `/Library/Developer/CommandLineTools/Library/Developer/Frameworks` and the interop runtime at `/Library/Developer/CommandLineTools/Library/Developer/usr/lib`.

## Limits

These are automated Store, AppKit menu-action and presentation checks. They do not establish physical shortcut entry, pointer context-menu use, VoiceOver speech or final visual approval. Note-window editing and flush-before-organization are later #88 slices; the organizer command boundary is the integration point for that coordination. Archive browsing/restore is also a later slice. No schema change, permanent deletion, live data mutation, installation or human interaction evidence is claimed.
