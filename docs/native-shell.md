# Native Hana — build and validation

Hana finds cached applications and indexed filenames, captures notes and tasks to the local Collection Store, and organizes committed content in Notes, Inbox, Today, Completed and Archive. Native note windows autosave source text, retain failed saves and offer a read-only Markdown preview. [#88](https://github.com/beamseree/hana/issues/88) records this implementation; [#99](https://github.com/beamseree/hana/issues/99) separates automated/native results from pending physical acceptance. The bar retains its blurred bezel, opaque card and native shadow. Current accepted behavior lives in the [product specification](product-spec.md); earlier native-shell evidence remains under [issue #10](evidence/issue-10/validation.md).

## Build, test, install and run

Requires the selected Xcode toolchain and a logged-in graphical macOS session for AppKit behavior tests. Swift Package Manager resolves the exact-pinned dependencies from `Package.swift`. The command line tools provide the Swift compiler; `xcodebuild` commands below additionally require full Xcode. The initial target is Apple Silicon, macOS 26.

```sh
xcode-select -p
xcodebuild -version
xcodebuild -checkFirstLaunchStatus
xcrun swift --version
xcrun --show-sdk-version

# Compile/typecheck during development; run a focused behavior test.
xcrun swift build
xcrun swift test --filter MacInteractionTests.oldDismissalCannotCloseAReopenedBar
# Complete suite; real AppKit suites must own windows sequentially.
xcrun swift test --no-parallel

# Provision/reuse a persistent personal signing identity, then bundle without installing.
./scripts/setup-signing
./scripts/build
./scripts/validate-signing
# Confirm the shared native testing slot is free. Quit only your own test app.
# Coordinate an existing Hana/prototype process with its owner before replacing it.
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

The build product is `build/Hana.app`; the repeatable installed location is `~/Applications/Hana.app`. `scripts/run` refuses replacement while Hana is running. Normal `open` uses the existing process; do not use `open -n` to start competing instances. The executable is `Hana`, with stable bundle identifier **com.beamseree.hana** and `LSUIElement=true`. The app is accessory with zero working windows and regular while any working window remains open, including minimized windows. Dock reopening explicitly opens or raises the main window.

Two global-focus tests use bounded signed disposable app subprocesses, because the Swift Testing async-main host does not run the native AppKit event loop. They require the original assertions and completion markers; no focus assertion is skipped or simulated. Minimized working windows let AppKit complete its native restore without an early extra key request.

On the Command Line Tools selected for #88 (Swift 6.3.3), Swift Testing needs explicit framework and interop search paths. If the plain test command cannot import `Testing`, use:

```sh
hana_developer="$(xcode-select -p)"
hana_frameworks="$hana_developer/Library/Developer/Frameworks"
xcrun swift test --no-parallel \
  -Xswiftc -F -Xswiftc "$hana_frameworks" \
  -Xlinker -F -Xlinker "$hana_frameworks" \
  -Xlinker -rpath -Xlinker "$hana_frameworks" \
  -Xlinker -rpath -Xlinker "$hana_developer/Library/Developer/usr/lib"
```

Coordinate native test processes with the shared `/tmp/hana-spec-88-native-lock` directory; acquire it atomically with `mkdir` and release only your own lock after the process exits. Leave keyboard/mouse idle during focus tests. Require the final Swift Testing test/suite summary as well as exit status: this CLT runner can exit early when an asynchronous native window close escapes a test's lifetime. The fixture app-loop harnesses cover native close/minimize behavior separately.

Earlier builds used ad-hoc signing with a per-build code hash as their designated requirement, which caused privacy grants to stop matching after updates. Personal builds now use one persistent certificate, provisioned by `scripts/setup-signing` and pinned outside the repository. Builds refuse ad-hoc fallback, and installation rejects an accidental signing-identity change. See [persistent signing](signing.md) for setup, the one-time permission migration, and the automated continuity check. This local certificate does not establish Developer ID distribution, notarization or physical permission-retention evidence. The app retains no entitlements, App Sandbox or Hardened Runtime; no script changes privacy grants or global shortcut/Spaces settings.

## Native behavior and boundary

`MacInteraction` owns presentation, native editing, invocation identity, dismissal, exclusive Option+Space registration, menu access and working-display placement on the main actor. `presentBar()` returns the active invocation; `dismiss(invocation, reason:)` ignores obsolete invocations. Reinvocation keeps the same editor and buffer. Dismissal clears text, marked text and undo history before a fresh session. Mouse callbacks capture their invocation, and temporary session observers are removed on dismissal.

The retained panel is nonactivating from construction, key-eligible but never main, at `.floating` (3). It uses `.canJoinAllSpaces`, `.fullScreenAuxiliary` and `.canJoinAllApplications`. It is a translucent, behind-window blurred bezel (always light, native window shadow) holding one opaque white card: the input row, with results extending the card below it when a query exists. Pixels outside the bezel's corners are transparent. The input is retained `NSTextView`, with native selection, paste and undo, near-black text/caret, and smart punctuation substitutions disabled. Empty Search shows only the Hana logo as Search's mode icon and a drawn "Search" placeholder, hidden during composition; no hints or results. Typed `-` and `[` enter Note and Task capture respectively; pasted symbols stay literal. The logo is `App/Resources/HanaLogo.svg`, copied into the bundle by `scripts/build`; unbundled SwiftPM runs show no icon. Native composition sees Escape first. Temporary native menu/key loss does not by itself dismiss Search; candidate IME verification remains explicitly deferred.

Escape orders out the nonactivating panel, releasing keyboard control to the still-active foreign origin where possible. No delayed origin activation is queued. Outside clicks and app/Space transitions dismiss without activating the old origin. The app does not attempt to reconstruct a foreign insertion point. For an app-owned origin, Escape restores its still-visible, nonminimized window and prior responder only while Hana remains the frontmost app. Explicit destination opening dismisses without origin restoration. Placement uses the app-owned focused window when Hana is the invocation origin. For a foreign origin, it checks existing Accessibility trust without prompting, then looks up only focused-window geometry off the input actor. Each AX element has a 15 ms messaging timeout; a separate 60 ms presentation deadline falls back without waiting for a late IPC reply. Untrusted, revoked, missing, invalid or failed geometry uses the pointer captured at invocation. AX coordinates are converted around the primary screen's top edge, including screens to the left or above it. The greatest window/display overlap chooses the display. The chosen visible frame and original input anchor are retained through expansion/contraction, with clamping only where needed to stay onscreen. Session identity fences a late lookup after dismissal/reopening. No permissions are requested or changed.

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


## Working windows

The menu-bar menu offers Search, Open Hana, shortcut status and Quit. **Window → Open Hana** (Command+1) and Dock reopen reach the same main window. The native Window menu also exposes Minimize (Command+M) and Close (Command+W). The main sidebar selects Notes, Inbox, Today, Completed and Archive. All five sections follow committed Collection Store observations; unavailable storage shows an explanation rather than an empty editable collection. Notes can be pinned, archived and opened with double-click or Return. Inbox/Today offer complete, move, inline rename and drag or keyboard ordering; Completed offers reopen, rename and archive. Archive interleaves notes/tasks with kind and completion labels and restores them without deleting content. Archived note windows are read-only until Restore. Native menu alternatives include Note → Open Note (Command+O), View sections (Command+2 through Command+6), and Markdown Preview (Option+Command+P) for the key note window. Organizer Pin/Archive/Open require the main Notes window to own key input. Quit freezes organizer and note input before awaiting pending saves; a refused task rename cancels quit and keeps its draft and explanation visible.

Only closing removes a working window from the registry; minimizing does not. An invocation-bound destination ignores an obsolete bar session before changing windows or focus. Ordinary Option+Space invocation does not activate Hana or order unrelated working windows. The historical mock destinations and focus probes described in [issue #4 evidence](evidence/issue-4/validation.md) were removed by #89; that record is prior evidence, not current controls.

`--validate-main-window --main-window-report PATH` runs the main-window app-loop harness with a disposable fixture Store. It never opens the live collection. Native state assertions and human-observed typing/focus remain separate; see [#89 evidence](evidence/issue-89/validation.md) and the extended [#96 checks](evidence/issue-96/validation.md). `--validate-note-window --note-window-report PATH` and `--validate-open-note-capture --open-note-capture-report PATH` exercise note lifecycle and capture opening with disposable fixtures. These flags do not open the live collection. The final persistent fixture and physical checklist belong to #99; do not use `scripts/run` to replace the installed app for those checks.

## Application Search — issue #5

Type an application name, move with ↑/↓, and press Return to open the selected path. Rows show Application and the full installation path; two installations remain separate. Application rows show that installation's real macOS icon, read by its exact URL off the main actor only when the row appears; until then, or if it can't be read, the generic application symbol holds the same 32-point frame, centred on the mode icon, with names starting at the query text. Result Icons keeps a bounded, session-only cache keyed by installation and its bundle/Info.plist stamps; macOS's own icon cache refreshes when the bundle directory changes, as an app update does. These are automated checks; installed-app screenshots are not yet recorded. File and folder rows keep their symbols. Empty Search has no results or hints. A selected result that disappears leaves no selection until you navigate again. Failed opening retains text and explains recovery. Successful native acknowledgment dismisses without restoring the invocation origin.

The retained native editor stays above the expanding results surface. Catalog scans and ranking run off its main actor. Search starts after approximately 100 ms debounce and returns at most 20 rows. The catalog enumerates at launch, then rescans only when FSEvents reports a change beneath a conventional application root that can alter it: a folder outside app bundles, an app bundle itself, or its Info.plist. Rescans are at least 2 s apart ([#154](evidence/issue-154/validation.md)). See [coverage, test procedures, timings and acceptance limits](evidence/issue-5/validation.md).


## Mixed filename Search — issue #6

Ordinary Search now merges applications with indexed filename results and visible folders. Rows include their type and exact location. All query tokens are literal filename matches; source status distinguishes gathering, partial coverage, and observed failure. An empty completed response does not diagnose permissions. Return opens the selected file in its default app; failure retains context.

The metadata adapter owns query lifecycle on the main run loop and sends value snapshots to background eligibility work. See [implementation, API checks and signed-app evidence](evidence/issue-6/validation.md) for bounds, the local-computer scope observation, and acceptance limits. `scripts/validation/install-file-search-fixtures` creates only named synthetic fixtures. `--validate-mixed-search` exercises their discovery/opening through Mac Interaction; `--validation-file-delay` adds five seconds to the file source for validation only. Both flags are opt-in. Broader coverage is recorded in [#9](evidence/issue-9/validation.md).


### Filename search access on this Mac

Permission evidence is build-specific. The [historical #6 run](evidence/issue-6/validation.md#resolution-user-granted-full-disk-access--2026-10-13) recorded Beam enabling Full Disk Access and subsequently seeing missing files. The later [#9 run](evidence/issue-9/validation.md) recorded successful Desktop/Documents/Downloads coverage after Beam allowed macOS prompts, with the exact prompt sequence uncertain. Neither run establishes a mandatory Full Disk Access setup or a diagnosis for every empty result set.

Start with existing permissions and record actual signed-app behavior. If a needed destination fails, preserve its observed error and discuss a concrete permission change with Beam before changing settings. Migration from the old ad-hoc signature to the persistent certificate needs one final approval; subsequent builds must retain the certificate-based designated requirement. An empty index response does not prove denial. Refine queries when a desired item falls outside the 20 visible results.

## Display and editing checks — issue #8

Run `xcrun swift test --filter DisplayPlacementTests` for geometry and bounded lookup behavior without presenting windows. `NativeEditingTests` and the existing Mac Interaction suites present real windows and hold the coordinated native testing slot (the `.nativeWindowSlot` suite trait), so no two of them run at once and `xcrun swift test` runs the complete suite in parallel. Give any new suite that presents windows the same trait. Native menu, paste, physical typing and pointer placement checks remain separate from deterministic geometry. See [issue #8 evidence](evidence/issue-8/validation.md) for the exact revision/build and acceptance state.

## Signed coverage and permissions — issue #9

See the [coverage/permission matrix](evidence/issue-9/validation.md) for tested identities, per-destination discovery/opening, user-approved privacy prompts, genuine denied/unavailable operations, deterministic failure checks and unavailable cases. Success in Desktop/Documents/Downloads was observed after Beam allowed macOS prompts; it is not a promise of prompt-free access or ad-hoc permission continuity.

The optional one-shot synthetic run is `scripts/validation/install-coverage-fixtures`, then `scripts/run --diagnostics --validate-coverage` while holding the shared native testing slot. Reuse or install the existing `install-app-search-fixtures` destinations first. The installer refuses existing roots. The runner renames/deletes only two marker-checked synthetic fixtures, probes known resource metadata, and uses production Search/Mac Interaction. Leave keyboard/mouse alone during the run; interference aborts it. Do not treat its open acknowledgment as observed document/focus behavior. Quit and relaunch without the validation flag for physical checks. Do not reset permissions or indexing to repeat a run.


## Integrated timing run — issue #10

While holding the native testing slot, quit your test app and run `./scripts/run --diagnostics --validate-performance`. Leave keyboard/mouse alone until Hana exits (normally about 35 seconds). The run uses the synthetic query `Hana`, existing indexed fixtures and conventional application roots; it neither creates nor opens destinations. It records one first-process sample and 30 warm samples, then quits and releases Option+Space. Relaunch the installed app with the same arguments for additional independent process runs; no rebuild is needed. OS and Spotlight caches are not flushed, so “cold” means process-cold only.

Integrated samples measure `presentBar()` call duration, native programmatic `insertText` call duration, and time from insertion start until app/file results are observable through Mac Interaction (2 ms polling, including the configured 100 ms debounce and rendering). Local-only samples separately use Search with zero debounce and no file adapter: delivery/ranking cost, excluding UI. A 5 ms cooperative heartbeat records excess main-actor scheduling delay, including system contention. These are proxies; none proves physical shortcut-to-typing p95 or absence of app-attributable physical typing stalls. Shared output contains timings/counts/display geometry, not query text or result paths. See the integrated report for sample counts, actual results and misses.

For an integrated late-file selection check, `scripts/validation/install-integrated-fixture` creates one marker-checked file at `~/Hana Issue 10 Validation/Hana Search Fixture.txt`. Reuse the two existing synthetic application installations. With `--diagnostics --validation-file-delay`, query `Hana Search Fixture`: applications remain usable during the five-second artificial file delay, then the file joins the results. Select the exact Two app across the arriving batch, open it, then repeat and choose the exact file. Verify the `HANA10-LATE-BATCH` marker and physical typing focus. This public-home fixture does not substitute for Desktop/Documents/Downloads permission coverage.

For the optional live-index queue regression (existing indexed Hana fixtures and the shared native testing slot required):

```sh
HANA_PERFORMANCE_CHECK=1 xcrun swift test --filter SearchResponsivenessTests
HANA_PERFORMANCE_CHECK=1 xcrun swift test -c release --filter SearchResponsivenessTests
```

The test initializes AppKit and measures independently produced callbacks from main-queue enqueue to execution, keeping the 50 ms maximum bound. It also prints the previous cooperative `Task.sleep` excess separately as a scheduling diagnostic. A late timer or producer before enqueue is outside the queue metric. Neither measurement proves physical shortcut-to-typing latency, rendered response, or universal typing-stall attribution. See the [timing follow-up](evidence/issue-10/timing-followup/validation.md) for regression sensitivity, sample counts and the complete all-options command.
