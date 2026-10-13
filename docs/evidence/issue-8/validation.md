# Issue #8 — working display and native editing

Scope: [#8](https://github.com/beamseree/hana/issues/8), under [#2](https://github.com/beamseree/hana/issues/2). No ranking, persistence, capture, organizer or prototype changes.

## Baseline and initial coordination

#6 was CLOSED and PR #14 MERGED. This worktree was advanced to its merge commit `b6399e17bd60e6f27d6fd410dd36759900ecb341`, then branch `codex/issue-8-display-and-editing` was created. The ancestry check passed. Beam confirmed this updated-main commit as the code-review fixed point.

#7 owned the first native slot. Beam explicitly answered "Keep waiting; #7 still owns it" after the handover request. At that checkpoint no app installation, launch, interactive windows, global-shortcut registration or other-checkout edits had been performed. The later authorized slot is recorded below.

## Implementation and automated evidence

Mac Interaction resolves captured displays/pointer and app-owned or AX-focused geometry through its geometry operation. AX reads only focused window, position and size when already trusted, off the input actor. Each element receives a 15 ms IPC timeout; an independent 60 ms deadline returns fallback without awaiting a noncooperative lookup. A dismissed invocation rejects late completion. No permission prompts/settings changes occur.

The display with greatest focused-window overlap wins; unavailable/offscreen/invalid geometry uses the captured pointer, with primary fallback if the pointer is not in a display. AX's top-left coordinates convert around the primary screen's top, not the selected screen. Expansion and contraction use the same retained visible frame and original top anchor. The native text editor remains retained; child/sheet windows belong to the session, and native menu tracking tolerates temporary key changes.

TDD slices: owned-window precedence; AX coordinates above primary; invalid geometry (the initial test failed because NaN selected a display); failed/nonresponsive AX lookup. Additional geometry cases cover pointer fallback, negative origins, small visible bounds, and expansion/contraction. All five geometry tests pass without any AppKit windows. The isolated Search run contained 16 tests total: 15 passed and one live-index fixture test was skipped because no fixture environment variable was supplied. Debug compilation/typechecking and local release bundling/plist/strict ad-hoc signature verification pass.

Prepared `NativeEditingTests` uses the actual key-window editor through Mac Interaction, controlled late result batches, English/Thai punctuation, selection, native undo/redo and input-top checks. At the initial pre-slot checkpoint it had not run because it presents windows; the complete suite was also pending. Both completed during the authorized slot below.

## Primary API evidence

Checked the selected Xcode 26.6 / Swift 6.3.3 SDK headers and Apple references:

- [AX messaging timeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout): timeouts are per element unless set on the system-wide object; both application and returned window therefore receive bounded timeouts.
- [AX trust](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted): query existing trust; no prompting options are used.
- `AXAttributeConstants.h`, `kAXPositionAttribute`: global top-left point, origin at the menu-bar screen's top-left, downward y, units in points. `kAXSizeAttribute` also uses points.

These are API capabilities, not observations of trusted cross-app behavior.

## Native acceptance procedure

During an explicitly handed-over slot: record commit, installed binary SHA-256/CDHash, signature, OS and available displays; test live changing results, ordinary English/Thai insertion and paste, selection, undo/redo, literal punctuation, native context menus, owned result controls, reinvocation and outside-click typing. Check each available display, app-owned placement and trusted foreign placement only if already authorized. Unavailable trust/display cases must be identified explicitly.

Candidate IME remains deferred. Display hot-plug, broad Stage Manager/sleep/lock hardening and privacy/Spaces/display setting changes remain outside scope. At the end, quit the test app and confirm process exit/shortcut release. Do not declare the PR ready until core native acceptance is complete and #7's merge state has been checked.


## Local build checkpoint — no installation or native run

Code revision: `bde8da0193c2a60bdf8b225b09f17c04d4e11e04`. macOS 26.4.1 (25E253), Xcode 26.6, Swift 6.3.3, arm64. Worktree-local `build/Hana.app`, bundle ID `com.beamseree.hana`, ad-hoc signature, no TeamIdentifier. Binary SHA-256 `6455668bc0f16349e8b702d0310304a55dbe1dfb6ef5edb1a4090a069dc3c769`; CDHash `2c62881f57911a310fd064f6c5facb53fb90f0ce`. This identifies the compiled candidate only, not an installed or native-tested build.

Five geometry tests were rerun after strengthening the unresponsive-IPC fixture; debug and release builds passed after the outside-click correction. Search's isolated run (15 passed, one skipped) completed before that Mac Interaction-only correction. At this pre-slot checkpoint the complete suite and NativeEditingTests had not run because they present windows. There was no installed/native-tested build and no slot had been acquired. These historical limits are superseded by the authorized-slot record below.

[Independent code review](review.md): zero Standards findings; one Spec acceptance gap (pending native checks), no confirmed code defect. #7 remained OPEN when checked before opening the draft. Recheck and incorporate updated main if #7 merges before readiness; any later interactive rerun needs a coordinated slot.


## Authorized native slot — 2026-10-13

Beam explicitly released #7's slot and authorized #8 to take it. No Hana process was running before installation. #7 was still OPEN and main remained `b6399e1`; no merge was needed at slot entry.

Exact tested source revision: `48ea2d2235aa5a2e7ea12141fcf3dcc33a14ef32` (same implementation as `bde8da0`; intervening commit only recorded evidence). Installed at `/Users/beamsereeyothin/Applications/Hana.app` using `scripts/run --diagnostics --validation-file-delay`. Bundle ID `com.beamseree.hana`; binary SHA-256 `6455668bc0f16349e8b702d0310304a55dbe1dfb6ef5edb1a4090a069dc3c769`; CDHash `2c62881f57911a310fd064f6c5facb53fb90f0ce`. Strict signature verification passed. No permission, global shortcut or display/Spaces settings were changed. The five-second file delay is an opt-in validation source delay, not normal behavior.

`xcrun swift test --no-parallel` completed 34 tests in five suites: 33 passed and one opt-in indexed-fixture test was skipped. The real AppKit native editing test passed both individually and in the full suite: 12 late results preserved the same responder, selection, English/Thai/literal buffer, input top, reinvocation and undo/redo. Logs: [full suite](full-tests.txt), [native editing](native-editing-tests.txt), [installation](native-install.txt).

### Live signed-app automation observations

After Beam physically invoked Search, UI automation observed:

- `TextEdit` initially showed its application and partial-file status. Real file batches subsequently increased results to 13 and 16, while runtime records retained `editorResponder=true` and the panel's top at 2292 points (height grew from 180 to 484).
- Pasting `- [ 'hello' *? บันทึก` preserved every literal character. Native Command-Z restored `TextEdit`; Command-Shift-Z restored the pasted string.
- Selecting `hello`, opening the actual NSTextView context menu, cancelling it, and typing `hello2` retained Search and replaced the selected text.
- Clicking the owned TextEdit result row and typing `X` produced `TextEditX` in the editor without dismissing Search.

Automated Option+Space inserted a space into the validation probe rather than reaching the global handler; Beam's physical shortcut supplied invocation evidence. The automation tool's Thai typing attempts produced no insertion, so ordinary physical Thai input is a separate human check, not inferred from successful paste/programmatic insertion. Candidate-based IME remains deferred.

### Available displays

Read-only [display inventory](displays.txt): built-in 1512×982 at (0,0), external 2560×1440 at (753,982), and external 2560×1440 at (-1807,982). Visible bounds are captured again at invocation; the menu-bar region can differ from the inventory snapshot. Runtime placement has already observed both `.owned` on the right external display and `.pointer` on the left external display. Physical per-display confirmation is recorded separately below.


### Physical checks and focus investigation

Beam explicitly confirmed the first editing check: ordinary English/Thai typing, select/replace, literal paste and undo/redo while results grew had no lost text, selection or unexpected input movement.

Beam then reported a core failure in the initial automation-driven process: invocation from another app displayed Search but typing went to that app; invocation from Main accepted typing. Runtime flags misleadingly reported both key panel and editor responder. The human-assisted `bash scripts/validation/foreign-input-loop` recorded `FOREIGN_INPUT=fail` (exit 1), using Beam's reported observation. This is retained as a real observed failure, not dismissed based on flags.

The unchanged installed binary was quit and relaunched at 16:05:16 ICT, with zero working windows and without native automation afterward. Beam confirmed foreign-app invocation then accepted typing (`FOREIGN_INPUT=pass`, exit 0). Next Beam physically invoked Search, opened Main using Command+1, clicked another app and invoked/typed again: this also passed in regular policy. Runtime native editor changes corroborate both accessory and regular foreign-origin typing. No implementation fix or cause has been established; clean relaunch cleared the observed symptom. Do not infer that a transient focus-state or automation-related cause has been proven.

Beam separately confirmed both precise menu checks: Escape closes the native context menu while Search remains and accepts `X`; with the menu open, clicking another app's disposable text field dismisses Search and immediate typing reaches that app without a second click. This covers the foreign-click/menu-notification ordering risk identified in review.


Beam also explicitly confirmed the three-display procedure and owned-window precedence: pointer placement on the built-in and both external displays, usable bounds during live result growth, reinvocation retaining the query, and invocation from Main staying on Main's display with the pointer elsewhere. This is grouped human confirmation. Runtime independently records pointer placement on both external displays and owned placement; it does not contain an isolated built-in-placement or repeated-invocation trace from that procedure.

Successful trusted cross-app AX placement was not demonstrated in this run; foreign-origin runtime placement used pointer fallback. Actual trust/lookup failure reason was not logged, so fallback is not evidence of a specific denied/revoked permission. The real trusted-success path remains explicitly untested; deterministic AX coordinate and deadline behavior passes. No additional grant was requested to make this path available.


### Final bounded focus repetition and limitations

Beam answered **"All six cycles pass"** to the final physical procedure using Claude, the previously failing app: three invoke/type/live-results → outside-click/type → reopen/type/Escape cycles with Main open, then three after closing Main. Search received the intended text, Claude received outside-click typing, and no extra click was needed. This is grouped human confirmation of six requested cycles, not a trace-derived cycle count. The [content-free runtime trace](native-runtime.jsonl) independently corroborates foreign-origin native editor changes and outside-click dismissals in both regular and accessory policies, including the last-working-window close. It does not isolate all six reported cycles or every substep.

The initial foreign-typing failure did not recur in the clean physical-only acceptance sequence. It remains an unresolved, nonreproducing observation from the earlier automation-driven process; no root cause or production code fix is claimed. Any recurrence should use `scripts/validation/foreign-input-loop`, preserving origin app, working-window state and native versus automated input conditions. AppKit key/responder flags alone must never count as a pass.

### Shutdown and readiness

Hana was quit after physical acceptance. `pgrep -x Hana` returned no process. The existing exclusive-shortcut fixture, compiled as `/tmp/hana-8-shortcut-release-probe`, successfully printed **"Reserved Option+Space exclusively"** (PID 99539), proving the app released registration. The probe was stopped with Control-C and its process absence confirmed. The native testing slot is released; subsequent interactive testing requires a new handover.

Installed binary SHA-256 was rechecked after testing and still matches the recorded tested identity. Only validation documentation and the human-assisted reproduction script were added after tested revision `48ea2d2`; production source remains unchanged. Candidate IME, trusted cross-app AX success, real denial/revocation, hot-plug and broad Stage Manager/sleep/lock cases remain explicitly untested/deferred. These are not presented as passes.

Before readiness, #7 was checked again: OPEN, no merged PR incorporated, remote main still `b6399e17bd60e6f27d6fd410dd36759900ecb341`. PR #15 reports MERGEABLE; no remote status checks are configured/reported. Local build/signature/full-suite and documented physical acceptance provide the scoped validation. No merge or new ticket was started.
