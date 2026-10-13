# Native Search shell — issue #3

This implements only [#3](https://github.com/beamseree/hana-searchbar/issues/3), under [parent #2](https://github.com/beamseree/hana-searchbar/issues/2). Search is an empty native input shell. There are no results, capture modes, working windows, or saved notes; `-`, `[`, pasted punctuation and Thai remain ordinary editor content. Hana is a local development label, not a final product name.

## Build, test, install and run

Requires the selected Xcode toolchain and a logged-in graphical macOS session for AppKit behavior tests. No dependencies or additional toolchain installation are needed. The initial target is Apple Silicon, macOS 26.

```sh
xcode-select -p
xcodebuild -version
xcodebuild -checkFirstLaunchStatus
xcrun swift --version
xcrun --show-sdk-version

# Compile/typecheck during development; run a focused behavior test.
xcrun swift build
xcrun swift test --filter MacInteractionTests.oldDismissalCannotCloseAReopenedBar
# Complete suite.
xcrun swift test

# Bundle, lint and ad-hoc sign without installing.
./scripts/build
# Quit any running Hana from its menu, and quit the old WF prototype first.
# Rebuild, install to the fixed location and launch via Launch Services.
./scripts/run
# Or opt in to content-free state/timing diagnostics for this process.
./scripts/run --diagnostics

codesign --verify --deep --strict --verbose=2 "$HOME/Applications/Hana.app"
codesign --display --verbose=4 "$HOME/Applications/Hana.app"
codesign --display --entitlements - "$HOME/Applications/Hana.app"
codesign --display -r- "$HOME/Applications/Hana.app"
security find-identity -v -p codesigning
```

The build product is `build/Hana.app`; the repeatable installed location is `~/Applications/Hana.app`. `scripts/run` refuses replacement while Hana is running. Normal `open` uses the existing process; do not use `open -n` to start competing instances. The executable is `Hana`, with stable bundle identifier **com.beamseree.hana** and `LSUIElement=true`. The app remains accessory with zero working windows; no Dock or Command-Tab presence is expected in this ticket.

No valid certificate identity was available on the tested Mac. The scripts explicitly use **ad-hoc signing**, no TeamIdentifier, no entitlements, no App Sandbox and no Hardened Runtime. Strict local signature validation is not notarization or public distribution readiness. The designated requirement for this ad-hoc build is a code hash; keeping the bundle identifier and installed path stable does **not** promise TCC permission continuity after a rebuild. No paid account is required for these local checks. No privacy grants or global shortcut/Spaces changes are performed.

## Native behavior and boundary

`MacInteraction` owns presentation, native editing, invocation identity, dismissal, exclusive Option+Space registration, menu access and pointer-display placement on the main actor. `presentBar()` returns the active invocation; `dismiss(invocation, reason:)` ignores obsolete invocations. Reinvocation keeps the same editor and buffer. Dismissal clears text, marked text and undo history before a fresh session. Mouse callbacks capture their invocation, and temporary session observers are removed on dismissal.

The retained panel is nonactivating from construction, key-eligible but never main, at `.floating` (3). It uses `.canJoinAllSpaces`, `.fullScreenAuxiliary` and `.canJoinAllApplications`. Its rounded interior is opaque white; pixels outside its corners are transparent. The input is retained `NSTextView`, with native selection, paste and undo, black text/caret, and smart punctuation substitutions disabled. Empty Search has no hints, buttons, modes or results. Native composition sees Escape first. Temporary native menu/key loss does not by itself dismiss Search; candidate IME verification remains explicitly deferred.

Escape orders out the nonactivating panel, releasing keyboard control to the still-active foreign origin where possible. No delayed origin activation is queued. Outside clicks and app/Space transitions dismiss without activating the old origin. The app does not attempt to reconstruct a foreign insertion point. Pointer placement uses that screen's `visibleFrame`, centers horizontally and clamps vertically and in size, including negative origins. Focused-window AX placement is later milestone work; this ticket uses the permitted initial pointer fallback without querying or requesting Accessibility.

`GlobalShortcut` uses HIToolbox's exclusive registration. On failure the menu-bar title becomes **Hana !**, and the menu shows the OSStatus plus **use Search**. Menu invocation is independent of registration. Quit and relaunch after resolving a conflict; do not change system shortcuts for this test.

## Diagnostics and test limits

Diagnostics are off unless launched with `--diagnostics`. The append-only JSONL file is `~/Library/Logs/Hana/native-shell.jsonl`, created with mode 0600 inside a 0700 directory. It records session IDs, event names, app bundle IDs, text length, composition state, screen/panel rectangles and native state flags. It never records query text, typed key values, window titles, captured text or personal filenames. Use disposable synthetic text when collecting shared evidence.

`presentationMilliseconds` measures synchronous presentation calls, including logging overhead; it does **not** measure physical invocation-to-typing readiness. A responder assignment, successful shortcut registration, build or screenshot does not establish keyboard focus. The behavior tests use real AppKit through Mac Interaction and verify session reuse and stale-dismissal rejection. There are no AppKit-call mocks or test-only public interfaces. Search behavior tests will belong to the later Search implementation.

Physical acceptance procedure (zero working windows):

1. In a normal app's disposable input, Option+Space and immediately type `- [ hello`. Verify only input appears and punctuation stays literal. Escape and type into the invocation origin without clicking it.
2. Repeat over another app's native full-screen Space; watch for an unwanted Space change on both invocation and dismissal.
3. Invoke/type, invoke again (same query), Escape/reopen (empty). Repeat rapidly.
4. Click outside into another app and type. Verify the clicked app retains focus. Repeat over full screen.
5. Invoke via **Hana → Search**. Check native English/Thai editing, select/paste/undo and editor context menus. Candidate-based IME checks remain deferred.
6. Move the pointer to each available display and invoke. Verify the whole bar is within the usable display area. Record unavailable displays/negative-coordinate cases as untested.

See [the evidence record](evidence/issue-3/validation.md) for this build's observations and outstanding checks. The isolated [prototype evidence](../prototypes/README.md) is prior art only; no prototype file was changed. Its previous physical passes do not establish this app's focus behavior.

## Primary references rechecked during implementation

- [Nonactivating panels](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel) and [full-screen eligibility](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications): individual API capabilities, not proof of the combined behavior.
- [Apple event monitoring guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html): main-thread mouse monitors, separate local/global coverage, removal when finished.
- Selected macOS 26.5 SDK `CarbonEvents.h`, `RegisterEventHotKey`: exclusive registration and `eventHotKeyExistsErr`. This app does not install a global keyboard monitor.
