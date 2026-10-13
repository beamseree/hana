# Issue #8 — working display and native editing

Scope: [#8](https://github.com/beamseree/hana/issues/8), under [#2](https://github.com/beamseree/hana/issues/2). No ranking, persistence, capture, organizer or prototype changes.

## Baseline and coordination

#6 was CLOSED and PR #14 MERGED. This worktree was advanced to its merge commit `b6399e17bd60e6f27d6fd410dd36759900ecb341`, then branch `codex/issue-8-display-and-editing` was created. The ancestry check passed. Beam confirmed this updated-main commit as the code-review fixed point.

#7 owns the first native slot. Beam explicitly answered "Keep waiting; #7 still owns it" after the handover request. No app installation, launch, interactive windows, global-shortcut registration or other-checkout edits have been performed by this work. Native checks below remain pending until explicit handover.

## Implementation and automated evidence

Mac Interaction resolves captured displays/pointer and app-owned or AX-focused geometry through its geometry operation. AX reads only focused window, position and size when already trusted, off the input actor. Each element receives a 15 ms IPC timeout; an independent 60 ms deadline returns fallback without awaiting a noncooperative lookup. A dismissed invocation rejects late completion. No permission prompts/settings changes occur.

The display with greatest focused-window overlap wins; unavailable/offscreen/invalid geometry uses the captured pointer, with primary fallback if the pointer is not in a display. AX's top-left coordinates convert around the primary screen's top, not the selected screen. Expansion and contraction use the same retained visible frame and original top anchor. The native text editor remains retained; child/sheet windows belong to the session, and native menu tracking tolerates temporary key changes.

TDD slices: owned-window precedence; AX coordinates above primary; invalid geometry (the initial test failed because NaN selected a display); failed/nonresponsive AX lookup. Additional geometry cases cover pointer fallback, negative origins, small visible bounds, and expansion/contraction. All five geometry tests pass without any AppKit windows. Sixteen Search tests pass; the live-index fixture test is skipped when no fixture environment variable is supplied. Debug compilation/typechecking and local release bundling/plist/strict ad-hoc signature verification pass.

Prepared `NativeEditingTests` uses the actual key-window editor through Mac Interaction, controlled late result batches, English/Thai punctuation, selection, native undo/redo and input-top checks. It has not been run yet because it presents windows. The complete suite is likewise pending.

## Primary API evidence

Checked the selected Xcode 26.6 / Swift 6.3.3 SDK headers and Apple references:

- [AX messaging timeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout): timeouts are per element unless set on the system-wide object; both application and returned window therefore receive bounded timeouts.
- [AX trust](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted): query existing trust; no prompting options are used.
- `AXAttributeConstants.h`, `kAXPositionAttribute`: global top-left point, origin at the menu-bar screen's top-left, downward y, units in points. `kAXSizeAttribute` also uses points.

These are API capabilities, not observations of trusted cross-app behavior.

## Native acceptance pending

During an explicitly handed-over slot: record commit, installed binary SHA-256/CDHash, signature, OS and available displays; test live changing results, ordinary English/Thai insertion and paste, selection, undo/redo, literal punctuation, native context menus, owned result controls, reinvocation and outside-click typing. Check each available display, app-owned placement and trusted foreign placement only if already authorized. Unavailable trust/display cases must be identified explicitly.

Candidate IME remains deferred. Display hot-plug, broad Stage Manager/sleep/lock hardening and privacy/Spaces/display setting changes remain outside scope. At the end, quit the test app and confirm process exit/shortcut release. Do not declare the PR ready until core native acceptance is complete and #7's merge state has been checked.


## Local build checkpoint — no installation or native run

Code revision: `bde8da0193c2a60bdf8b225b09f17c04d4e11e04`. macOS 26.4.1 (25E253), Xcode 26.6, Swift 6.3.3, arm64. Worktree-local `build/Hana.app`, bundle ID `com.beamseree.hana`, ad-hoc signature, no TeamIdentifier. Binary SHA-256 `6455668bc0f16349e8b702d0310304a55dbe1dfb6ef5edb1a4090a069dc3c769`; CDHash `2c62881f57911a310fd064f6c5facb53fb90f0ce`. This identifies the compiled candidate only, not an installed or native-tested build.

Five geometry tests were rerun after strengthening the unresponsive-IPC fixture; debug and release builds passed after the outside-click correction. Search's sixteen isolated tests passed before that Mac Interaction-only correction. The complete suite and NativeEditingTests have not run because they present windows. Native installed-build identity and native tested revision: **none yet**. No testing slot was acquired, so no app shutdown or slot-release claim is made.

[Independent code review](review.md): zero Standards findings; one Spec acceptance gap (pending native checks), no confirmed code defect. #7 remained OPEN when checked before opening the draft. Recheck and incorporate updated main if #7 merges before readiness; any later interactive rerun needs a coordinated slot.
