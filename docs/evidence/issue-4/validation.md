# Issue #4 working-window validation — 2026-10-13

Scope: [#4](https://github.com/beamseree/hana-searchbar/issues/4), under parent #2. Branch `codex/issue-4-working-windows`; review baseline `d71eee798674c2a6a8800ef4977bde4e21db9243` (merged PR #11), confirmed by Beam. GitHub #3 is closed, PR #11 is merged, and its merge commit is an ancestor of this branch. No other ticket is implemented.

## Environment and build

- macOS 26.4.1 (25E253), Apple Silicon; startup reports two screens.
- Selected `/Applications/Xcode-26.6.app/Contents/Developer`, Xcode 26.6 (17F113), Swift 6.3.3, macOS SDK 26.5; first-launch check succeeded.
- Installed identity `com.beamseree.hana`, `~/Applications/Hana.app`, version 0.1.0 (1). CDHash `87a413ad2bef32db0b35d553ff83a61cbbf35fa4`.
- Ad-hoc signature, no TeamIdentifier or valid signing certificate available. Existing unsandboxed identity retained; no new entitlements or privacy/shortcut/Spaces settings. Local signature success does not establish distribution readiness or permission continuity.
- Release build, plist lint and strict bundle signature validation passed. Launch Services started the installed build with `--diagnostics`; startup at 05:37:14 UTC reports accessory activation, zero working windows, level 3, and shortcut registration OSStatus 0.
- An early automation attachment launched the previous installed app during the build; that process was stopped and the new installed app was explicitly relaunched. Only the diagnostic session beginning 05:37:14 UTC belongs to this validation.

## Automated checks

The pre-agreed interface remains Mac Interaction for native runtime checks; no standalone registry seam or mocked AppKit adapter was added. Search is not implemented in this ticket.

- TDD at the existing Mac Interaction session boundary: `oldDestinationCannotCloseAReopenedBar` first failed to compile because destination opening did not exist, then passed. An obsolete destination request returns false and leaves the newer invocation intact. It does not prove physical focus.
- Final `xcrun swift test`: **3 Swift Testing tests passed**, 0 failures, 0.463 seconds. This includes existing reinvocation identity and stale-dismissal tests. XCTest's separate compatibility header reports zero XCTest tests.
- Debug/release compilation, `bash -n scripts/build scripts/run`, and `git diff --check` passed.

## Runtime matrix

The [content-free runtime capture](runtime.jsonl) records this build only. State traces corroborate lifecycle, never physical keyboard routing, Space transitions, or animation endpoints. User observations below will be recorded separately and literally enough to preserve their scope. Pending means not established in this build, even if prototype #1 or shell #3 passed it.

| Case / procedure | Expected | Current evidence | Status |
| --- | --- | --- | --- |
| Main + two mock notes | Three independently identified ordinary windows; opening the same ID reuses it | Trace at 05:38:55 UTC contains IDs 1/2/3; repeated open events reuse them, never add a fourth | Runtime pass |
| Mock boundary | Clear validation-only/no-saving labels; temporary probe is not note editing | Native accessibility tree and rendered Main window show validation-only/no-saving disclaimer and temporary probe label | Automated UI pass |
| Registry / activation | Regular from first open until final close, including minimized windows | 05:38:47 regular with Main; 05:39:40 closes retain regular; 05:39:41 last close switches accessory; reopening switches regular | Partial runtime pass; minimized case pending |
| Full-screen, all open | Physical Option+Space/type/Escape; no Space jump or unrelated-window raising; origin receives typing after Escape | Explicit physical procedure requested | Pending human check |
| Full-screen, all minimized | Same invocation/typing behavior while all three remain minimized | Not yet observed | Pending human check |
| Dock / Command-Tab | App remains reachable with open or minimized windows; Dock opens Main only | Not yet observed | Pending human check |
| Destination from bar | ⌘2 opens/focuses Mock Note A; immediate physical typing reaches its probe without click or stale restoration | Explicit physical procedure requested | Pending human check |
| Owned-origin Escape | Invoke from a working-window probe; Escape returns typing to that same probe | Source restoration guarded by origin identity, visibility and minimization | Pending human check |
| Last close / repeated transitions | Accessory only after last close; menu Search and global invoke/type/Escape still work; close/reopen and rapid Escape/reinvoke stay stable | No delayed restore callbacks; stale-session tests pass | Pending native/human checks |
| Single yellow button | Native animation goes to Dock | No animation overrides; current run unobserved | Pending human check |
| Bulk minimize | All three animate to Dock and stay registered | Native `miniaturize` calls; current run unobserved | Pending human check |
| Close all → reopen three → bulk | Same Dock endpoints across policy transitions | Current run unobserved | Pending human check |

## Physical continuation procedure

1. Open all three through Hana menu; repeat Open Mock Note A and verify no duplicate. In a foreign app's native full-screen Space, invoke/type/Escape and type back in the original field. Check Dock and Command-Tab access, no unexpected Space switch, and no unrelated-window raising.
2. Invoke there again, press ⌘2, immediately type into Mock Note A's probe without clicking. This intentional destination Space change is distinct from an unwanted invocation jump. Invoke from that probe and Escape; type again to check owned-origin restoration.
3. Click Main's yellow button and report the animation endpoint. Reopen Main. Choose Minimize all working windows; watch each endpoint. With all three minimized, repeat full-screen invoke/type/Escape. Check Dock/Command-Tab presence. Click the Dock icon: Main should become reachable without unminimizing either note.
4. Close all, verify menu Search and physical Option+Space/type/Escape with zero windows. Reopen all three, then bulk minimize and observe endpoints again. Repeat close/reopen plus rapid invocation/Escape/reinvoke; verify no stale restoration or lost typing. Check an outside click into a foreign field lets that field receive typing.

## Prototype and documented capability

Read-only Git-object inspection of preserved [#1 matrix](https://github.com/beamseree/hana-searchbar/blob/prototype/window-focus/prototypes/window-focus/TEST-MATRIX.md) and [minimize investigation](https://github.com/beamseree/hana-searchbar/blob/prototype/window-focus/prototypes/window-focus/debug/MINIMIZE-INVESTIGATION.md) informed this implementation. No prototype file or branch was changed.

The original sequential-bulk top-left animation report remains unexplained. The prototype's later single, bulk, and close-all/reopen/bulk observations all went toward the Dock, with unchanged native window behavior. That is neither a diagnosed cause nor a verified fix; current results must be recorded independently. No animation suppression, delay workaround, extreme panel level, helper, or global settings change was introduced. ADR 0005 remains **proposed**.

Apple documentation checked during implementation: [reopen callback](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)) allows custom reopen handling and explicitly counts minimized windows in its visibility flag; this app handles Main regardless of that flag and returns false to suppress default handling. [Policy change](https://developer.apple.com/documentation/appkit/nsapplication/setactivationpolicy(_:)) returns acceptance, and [miniaturize](https://developer.apple.com/documentation/appkit/nswindow/miniaturize(_:)) describes native Dock minimization. These individual API capabilities do not certify combined full-screen/focus/animation behavior.

## Code review

### Standards

Independent standards review of `d71eee7...01673e6`: **0 findings**. Main-actor Mac Interaction ownership, AppKit controllers, typed validation destinations and evidence separation conform to the repository rules. No actionable baseline smell was reported.

### Spec

Independent spec review of the same diff: **0 code defects**, **0 scope-creep findings**, **1 acceptance-evidence gap**. The missing evidence is physical full-screen/open/minimized invocation, destination typing, Dock/Command-Tab, last-close/rapid transitions and animation endpoints. These remain explicit gates, not inferred passes.

Review totals: Standards **0** (no worst issue); Spec **1** (core physical acceptance pending).

## Remaining limitations

Core physical acceptance is pending, so the PR must remain draft until those checks are complete. Candidate-based IME testing remains explicitly deferred for current English/Thai use. Focused-window AX placement, display disconnect, lock/sleep, Stage Manager and other full-screen apps are unverified. No persistence, real note editing, organizer or search results were added. Builds, screenshots, launch acknowledgment and responder flags are not focus proof.
