# Issue #89 — Main window and live Notes

2026-10-15, Asia/Bangkok. Comparison base: `4d1a57c4a8f579dd156201e77edc896aa611330a`. Implementation commit: `80264c8` (the native run used this exact source; subsequent changes are evidence only).

## Delivered behavior

One ordinary, titled, resizable AppKit main window hosts SwiftUI. Notes, Inbox, Today, Completed and Archive are selectable in the sidebar. Notes observes the Collection Store's active `.notes` query without reordering it; rows have stable note IDs, first-nonempty-line titles (Untitled fallback) and pin indicators. The other sections are placeholders. There are no editing controls in this slice. Missing collection, failed opening and failed observation have typed unavailable states, with rows cleared rather than showing a misleading empty collection.

Mac Interaction exposes presentation and registered native windows. Main identity is independent of section; repeated opening reuses the window, optional section changes navigation, and unspecified section preserves selection. Closing cancels observation; reopening reads current Store state. Mock note windows, temporary text probes and validation-only menu items are removed. Menu-bar Open Hana, Window/Open Hana, Command+1 and the Dock reopen delegate route to the main destination.

## Automated checks

- `initial-red.txt`: the first Notes integration test failed to compile because Mac Interaction had no main-window presentation API. The same test passed after the implementation.
- `focused-tests.txt`: four MainWindowTests passed (five executions, including the missing/failed Store parameter cases). Real disposable SQLite Stores verify active note ordering, pin priority, first-line titles, a newly committed note arriving while open, Store-close unavailability, empty versus unavailable state, section selection, singleton reuse, minimization policy, close/reopen, menu-bar/Window menu and Dock delegate routing. Unavailable windows contain no editable native text controls.
- `build.txt`: release build, bundle property-list validation and ad-hoc signature verification passed with Swift 6.3.3 / Xcode 26.6.
- `full-tests.txt`: `xcrun swift test --no-parallel` passed all 311 tests in 40 suites (47.754 seconds). This includes existing capture, native editor, destination and Search regressions; no default suite was excluded. Opt-in environment-dependent tests retain their existing conditions. In the saved log, literal carriage returns and trailing spaces/tabs in parameter values are escaped for readable, whitespace-clean evidence; the original test output is otherwise preserved.

## Native app run and visual inspection

Beam handed over the native testing slot explicitly. Ran the built binary in an isolated bundle at `/tmp/hana-89-native/Hana-Issue89.app`, with identifier `com.beamseree.hana.validation.issue89`. The already-running installed Hana process was left running. The fixture app creates a new marked disposable root, opens only that Store, removes it after closing, and quits its own process. No install, live collection, privacy, shortcut preference or Spaces setting was changed.

Command: `Hana --validate-main-window --main-window-report /tmp/hana-89-native/final-runtime.jsonl --preview-main-window`.

Tested binary SHA-256: `34d07a6c77c8ffc5bf690ed991e923f51d5b26f17ec121c16ce8a96c6ddc6f15` (ad-hoc signed validation bundle). `native-runtime.jsonl` records a passing app run:

- Main window becomes AppKit key in regular activation policy, and shows the fixture note.
- Reopening with a section preserves the window identity.
- The nonactivating bar gets its native editor responder; Escape restores the main window's captured responder.
- A native editor Note capture commits, closes the bar, appears in the open Notes list and restores the main window responder.
- Minimization retains regular policy; invoking the actual app delegate's Dock-reopen handler deminiaturizes the same window.
- Closing the last window removes membership and changes to accessory policy.

CUA screenshot and accessibility inspection showed all five sidebar labels, both saved note rows, the native window chrome and no temporary focus field. Clicking Today showed its placeholder; clicking Notes returned to the live rows. An earlier view-cache bitmap omitted the system sidebar layers; it was discarded and replaced by inspection of the actual window.

## Limits and initial failures

SwiftPM's test runner does not establish key-window state for ordinary working windows in this environment. Initial combined key-window/capture checks failed there; no product focus change was made to force a runner pass. Those checks run instead in the real app event loop through the opt-in, fixture-only `--validate-main-window` harness. Runner minimization assertions required waiting for completion, and window tests now use Mac Interaction's registered window identity rather than matching stale closed windows retained by AppKit. The final native app rerun ran alone, after the runner tests finished.

These are automated AppKit state and CUA visual/accessibility observations. No new human-observed physical typing, foreign-app/full-screen/Spaces, Command-Tab or IME acceptance is claimed. Earlier evidence and deferred physical timing remain unchanged; ADR 0005 remains proposed. Inbox/Today/Completed/Archive behavior, note windows, organization actions, autosave and automatic backups/restore remain outside #89. The fixture app quit and the native testing slot was explicitly released after the full-suite run. The issue remains open pending normal review/merge; no PR, tracker closure or push is performed by this implementation request.
