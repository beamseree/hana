# Native Search and validation windows — issues #3–5

This implements [#3](https://github.com/beamseree/hana/issues/3) and [#4](https://github.com/beamseree/hana/issues/4), under [parent #2](https://github.com/beamseree/hana/issues/2). Search finds installed applications from a cached catalog and launches the selected installation. Three ordinary working windows contain clearly labeled validation content and temporary keyboard focus probes. There are no file results, capture modes, real note editing, organizer, or saved notes; `-`, `[`, pasted punctuation and Thai remain ordinary editor content. Hana is a local development label, not a final product name.

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

The build product is `build/Hana.app`; the repeatable installed location is `~/Applications/Hana.app`. `scripts/run` refuses replacement while Hana is running. Normal `open` uses the existing process; do not use `open -n` to start competing instances. The executable is `Hana`, with stable bundle identifier **com.beamseree.hana** and `LSUIElement=true`. The app is accessory with zero working windows and regular while any working window remains open, including minimized windows. Dock reopening explicitly opens/focuses Main, leaving the two mock note windows alone.

No valid certificate identity was available on the tested Mac. The scripts explicitly use **ad-hoc signing**, no TeamIdentifier, no entitlements, no App Sandbox and no Hardened Runtime. Strict local signature validation is not notarization or public distribution readiness. The designated requirement for this ad-hoc build is a code hash; keeping the bundle identifier and installed path stable does **not** promise TCC permission continuity after a rebuild. No paid account is required for these local checks. No privacy grants or global shortcut/Spaces changes are performed.

## Native behavior and boundary

`MacInteraction` owns presentation, native editing, invocation identity, dismissal, exclusive Option+Space registration, menu access and pointer-display placement on the main actor. `presentBar()` returns the active invocation; `dismiss(invocation, reason:)` ignores obsolete invocations. Reinvocation keeps the same editor and buffer. Dismissal clears text, marked text and undo history before a fresh session. Mouse callbacks capture their invocation, and temporary session observers are removed on dismissal.

The retained panel is nonactivating from construction, key-eligible but never main, at `.floating` (3). It uses `.canJoinAllSpaces`, `.fullScreenAuxiliary` and `.canJoinAllApplications`. It is a translucent, behind-window blurred bezel (always light, native window shadow) holding one opaque white card: the input row, with results extending the card below it when a query exists. Pixels outside the bezel's corners are transparent. The input is retained `NSTextView`, with native selection, paste and undo, near-black text/caret, and smart punctuation substitutions disabled. Empty Search shows only the Hana logo as Search's mode icon and a drawn "Search" placeholder, hidden during composition; no hints, buttons, other modes or results. The logo is `App/Resources/HanaLogo.svg`, copied into the bundle by `scripts/build`; unbundled SwiftPM runs show no icon. Native composition sees Escape first. Temporary native menu/key loss does not by itself dismiss Search; candidate IME verification remains explicitly deferred.

Escape orders out the nonactivating panel, releasing keyboard control to the still-active foreign origin where possible. No delayed origin activation is queued. Outside clicks and app/Space transitions dismiss without activating the old origin. The app does not attempt to reconstruct a foreign insertion point. For an app-owned origin, Escape restores its still-visible, nonminimized window and prior responder only while Hana remains the frontmost app. Explicit destination opening dismisses without origin restoration. Pointer placement uses that screen's `visibleFrame`, centers horizontally and clamps vertically and in size, including negative origins. Focused-window AX placement is later milestone work; this ticket uses the permitted initial pointer fallback without querying or requesting Accessibility.

`GlobalShortcut` uses HIToolbox's exclusive registration. On failure the menu-bar title becomes **Hana !**, and the menu shows the OSStatus plus **use Search**. Menu invocation is independent of registration. Quit and relaunch after resolving a conflict; do not change system shortcuts for this test.

## Diagnostics and test limits

Diagnostics are off unless launched with `--diagnostics`. The append-only JSONL file is `~/Library/Logs/Hana/native-shell.jsonl`, created with mode 0600 inside a 0700 directory. It records session IDs, event names, app bundle IDs, text length, composition state, screen/panel rectangles and native state flags. It never records query text, typed key values, window titles, captured text or personal filenames. Use disposable synthetic text when collecting shared evidence.

`presentationMilliseconds` measures synchronous presentation calls, including logging overhead; it does **not** measure physical invocation-to-typing readiness. A responder assignment, successful shortcut registration, build or screenshot does not establish keyboard focus. The behavior tests use real AppKit through Mac Interaction and verify session reuse and stale-dismissal rejection. There are no AppKit-call mocks or test-only public interfaces. Search behavior tests exercise the query-to-batches interface and filesystem adapter; application destination tests exercise Mac Interaction with controlled native-opening outcomes.

Physical acceptance procedure (zero working windows):

1. In a normal app's disposable input, Option+Space and immediately type `- [ hello`. Verify only the logo, placeholder and input appear, the placeholder disappears on the first keystroke, and punctuation stays literal. Escape and type into the invocation origin without clicking it.
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

## Reproduce the registration conflict

Quit Hana and the WF prototype. In one terminal, reserve Option+Space using the small runtime fixture (a separate process, not a mock of Hana):

```sh
xcrun swiftc scripts/validation/hold-shortcut.swift -o /tmp/hana-hold-shortcut
/tmp/hana-hold-shortcut
```

While it reports a successful reservation, launch the installed Hana app in another terminal:

```sh
open "$HOME/Applications/Hana.app" --args --diagnostics
```

Verify **Hana !**, the unavailable-shortcut menu message, and working **Search** menu invocation/typing. Stop the fixture with Control-C, quit Hana, and relaunch Hana. Startup should report registration status 0 and physical Option+Space should work again. This does not modify shortcut preferences or privacy settings.


## Working-window validation controls — issue #4

Hana's menu-bar menu and the native **Window** menu offer **Open Main**, **Open Mock Note A**, **Open Mock Note B**, **Minimize all working windows**, and **Close all working windows**. The Window menu also exposes native Minimize (⌘M) and Close (⌘W). Each open action reuses its existing window, deminiaturizing only the requested destination if needed. Closing discards that window's temporary focus-probe text; no collection or note exists.

From the bar, **⌘1**, **⌘2**, and **⌘3** open/focus Main, Mock Note A, and Mock Note B respectively. These are validation shortcuts, not search results or capture commands. Empty Search stays input-only. Destination opening requests activation explicitly from the current frontmost app and selects its labeled keyboard focus probe. Naming that source fixed the physically reproduced failure where a plain activation request left Notes active in its full-screen Space. Activation acknowledgment alone is not focus proof. Normal Option+Space presentation neither activates Hana nor changes policy or orders working windows.

The registry is internal to Mac Interaction and owns retained AppKit window controllers keyed by three typed validation destinations. Only closing removes membership; minimizing does not. The app delegate routes Dock reopening to `open(.main)` and suppresses AppKit's default reopen handling. An invocation-bound `open(destination, from:)` ignores an obsolete session before touching any window or focus. No delayed activation/restore callback is scheduled.

Working-window diagnostics add numeric validation IDs (1 Main, 2 Mock Note A, 3 Mock Note B), minimized/visible/key/active-Space state, open/close/minimize events, and activation-policy transition success. Probe contents are not logged. See the [issue #4 runtime matrix](evidence/issue-4/validation.md) for current evidence and the physical procedure. Prior #1/#3 observations are not automatically passes for this integration.


## Application Search — issue #5

Type an application name, move with ↑/↓, and press Return to open the selected path. Rows show Application and the full installation path; two installations remain separate. Empty Search has no results or hints. A selected result that disappears leaves no selection until you navigate again. Failed opening retains text and explains recovery. Successful native acknowledgment dismisses without restoring the invocation origin.

The retained native editor stays above the expanding results surface. Catalog scans and ranking run off its main actor. Search starts after approximately 100 ms debounce and returns at most 20 rows. The catalog refreshes at launch and when a one-second directory/metadata stamp check detects changes inside conventional application roots. See [coverage, test procedures, timings and acceptance limits](evidence/issue-5/validation.md).


## Mixed filename Search — issue #6

Ordinary Search now merges applications with indexed filename results and visible folders. Rows include their type and exact location. All query tokens are literal filename matches; source status distinguishes gathering, partial coverage, and observed failure. An empty completed response does not diagnose permissions. Return opens the selected file in its default app; failure retains context.

The metadata adapter owns query lifecycle on the main run loop and sends value snapshots to background eligibility work. See [implementation, API checks and signed-app evidence](evidence/issue-6/validation.md) for bounds, the local-computer scope observation, and acceptance limits. `scripts/validation/install-file-search-fixtures` creates only named synthetic fixtures. `--validate-mixed-search` exercises their discovery/opening through Mac Interaction; `--validation-file-delay` adds five seconds to the file source for validation only. Both flags are opt-in. Broader coverage remains #9.


### Filename search access on this Mac

For the verified local build, enable **System Settings → Privacy & Security → Full Disk Access → Hana**, selecting `~/Applications/Hana.app`, then quit and reopen Hana. Beam performed this change explicitly; it made previously missing ordinary Documents and Downloads filename results appear in the normally launched app. This is broader access than filenames: macOS allows access to protected files and other apps' data. See [Apple's permission descriptions](https://support.apple.com/en-om/guide/mac-help/mchl211c911f/mac). No Spotlight reindex or folder-selection setup was needed.

Full Disk Access is verified sufficient for the reported case; narrower per-folder grants were not tested. A completed empty search is not proof of a missing grant, and Hana does not infer permission denial from it. Refine broad queries when the desired file falls outside the 20 displayed results.

This app currently uses ad-hoc signing with a binary-specific designated requirement. After rebuilding, a previous Full Disk Access entry may no longer authorize the new binary; remove and re-add the installed app if necessary, then repeat the signed-app check. A stable certificate-backed signing identity remains a separate setup concern. See [permission and runtime evidence](evidence/issue-6/validation.md#resolution-user-granted-full-disk-access--2026-10-13).
