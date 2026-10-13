# Throwaway native window/focus prototype

Question: can one process provide a nonactivating typing panel over another app's full-screen Space while ordinary working windows retain Dock and Command-Tab access?

This is an AppKit experiment, not the production app. All writing is disposable mock content. There is no storage, search, organizer, autosave, complete editor, or SwiftUI dependency. The main and two note windows exist only to exercise window ownership. Opening a note from the bar copies text into a new mock window; it does not save anything. Opening an already-open mock window preserves that window's text.

## Build and run

On the verified Apple Silicon Mac, with Xcode 26.6 selected:

```sh
cd /Users/beamsereeyothin/Documents/Projects/macos-shapeshifting-searchbar
./prototypes/window-focus/run.sh
```

Build only: `./prototypes/window-focus/build.sh`. This compiles Swift 6 directly with the macOS SDK, creates a local app bundle, and ad-hoc signs it. It does not install dependencies, change Xcode selection, request privacy permissions, or modify system settings. Deployment target is macOS 26.0. Ad-hoc signing is sufficient for this local experiment, not production distribution.

Quit the running prototype using **WF → Quit prototype** before rebuilding; opening an already-running bundle does not replace its executable in memory.

## Controls

- **Option+Space**: invoke; repeat to refocus the same capture without clearing it. Registered exclusively through HIToolbox. A **WF !** status title means registration failed; menu invocation remains available.
- **WF** menu-bar item: show bar, open Main / Note A / Note B, minimize all, close all, record a checkpoint, quit.
- **Escape**: dismiss and discard. During marked text it goes to the native text input system first.
- **Outside click**: dismiss without reactivating the invocation origin. Native context menus and marked-text candidate interactions have conservative guards that require interactive validation.
- Bar buttons open each mock window or expand/shrink the same editor. Expansion is immediate; animation and finished visual design are outside this experiment.
- Main / Note A / Note B are independent titled, resizable, minimizable windows. Closing the final working window keeps the process and menu-bar item alive.
- The menu's Command-1/2/3 shortcuts provide convenient access while the prototype is active. They are not proposed product shortcuts.

The bar uses `.nonactivatingPanel` at construction, `.floating` (3), `.canJoinAllSpaces`, `.fullScreenAuxiliary`, and `.canJoinAllApplications`. The nonactivating style never changes. The working-window registry controls accessory versus regular policy and includes minimized windows. No production helper or XPC contract is implemented unless evidence justifies a separate experiment.

## State and evidence

A compact line below the editor shows policy, working-window count, session, and the latest event. Diagnostic JSON lines are written to:

```sh
getconf DARWIN_USER_TEMP_DIR
# Within that directory: window-focus-prototype.jsonl
```

The log is reset on each launch. It contains timestamps, application bundle identities, window flags and geometry, session IDs, selection ranges, text length, composition state, and event names. It does **not** contain editor text, typed character values, filenames, or captured content. Keyboard diagnostics distinguish Escape from other keys only; there is no global keyboard monitor. The evidence-copy script removes key codes from earlier diagnostic builds. Use only mock text.

Preserve a run and print its transitions:

```sh
python3 prototypes/window-focus/capture-evidence.py
```

See [TEST-MATRIX.md](TEST-MATRIX.md) for evidence and outstanding checks. `isKeyWindow`, `isOnActiveSpace`, responder assignment, and successful registration are diagnostic signals, not proof of visible placement or physical keyboard routing. In particular, this run has reported `NSApp.isActive == true` while the workspace frontmost application remained Figma; do not equate that flag alone with stealing the other app's activation.

No Accessibility permission is requested. If existing permission is available, the prototype makes a bounded focused-window geometry query. Otherwise it uses the display containing the pointer, as the product permits. AX placement remains unverified when permission is absent. Display-change handling dismisses the bar; negative-coordinate geometry needs physical placement checks.

## Isolation and capture

The original experiment was committed in an independent local repository. This published `prototype/window-focus` branch preserves that history as ancestry and places the experiment under `prototypes/window-focus/` alongside the project documentation. Build artifacts are excluded. Clone this branch separately from the original working directory as described in `prototypes/README.md`. No production target is created; the prototype remains explicitly disposable.
