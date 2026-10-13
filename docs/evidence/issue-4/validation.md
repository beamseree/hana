# Issue #4 working-window validation — 2026-10-13

Scope: [#4](https://github.com/beamseree/hana-searchbar/issues/4), under parent #2. Branch `codex/issue-4-working-windows`; review baseline `d71eee798674c2a6a8800ef4977bde4e21db9243` (merged PR #11), confirmed by Beam. GitHub #3 is closed, PR #11 is merged, and its merge commit is an ancestor of this branch. No other ticket is implemented.

## Environment and build

- macOS 26.4.1 (25E253), Apple Silicon; startup reports two screens.
- Selected `/Applications/Xcode-26.6.app/Contents/Developer`, Xcode 26.6 (17F113), Swift 6.3.3, macOS SDK 26.5; first-launch check succeeded.
- Installed identity `com.beamseree.hana`, `~/Applications/Hana.app`, version 0.1.0 (1). Initial CDHash `87a413ad2bef32db0b35d553ff83a61cbbf35fa4`; final CDHash `142b63469384a80ff87760d2d6cb027bf54ad642`. Diagnostic/final runs are also identified by their startup timestamps below.
- Ad-hoc signature, no TeamIdentifier or valid signing certificate available. Existing unsandboxed identity retained; no new entitlements or privacy/shortcut/Spaces settings. Local signature success does not establish distribution readiness or permission continuity.
- Release build, plist lint and strict bundle signature validation passed. Launch Services started the installed build with `--diagnostics`; startup at 05:37:14 UTC reports accessory activation, zero working windows, level 3, and shortcut registration OSStatus 0.
- An early automation attachment launched the previous installed app during the build; that process was stopped and the new installed app was explicitly relaunched. This report includes diagnostic sessions from 05:37:14 UTC onward; it excludes earlier #3 runs. Final activation-fix candidate was installed and launched at 05:54:23 UTC.

## Automated checks

The pre-agreed interface remains Mac Interaction for native runtime checks; no standalone registry seam or mocked AppKit adapter was added. Search is not implemented in this ticket.

- TDD at the existing Mac Interaction session boundary: `oldDestinationCannotCloseAReopenedBar` first failed to compile because destination opening did not exist, then passed. An obsolete destination request returns false and leaves the newer invocation intact. It does not prove physical focus.
- Final `xcrun swift test`: **3 Swift Testing tests passed**, 0 failures, 0.217 seconds after the activation fix. This includes existing reinvocation identity and stale-dismissal tests. XCTest's separate compatibility header reports zero XCTest tests.
- Debug/release compilation, `bash -n scripts/build scripts/run`, and `git diff --check` passed.

## Runtime matrix

The [content-free runtime capture](runtime.jsonl) records the issue #4 initial, diagnostic and final runs. State traces corroborate lifecycle, never physical keyboard routing, Space transitions, or animation endpoints. User observations below are recorded separately with their scope. Prior prototype #1 and shell #3 passes were not counted as current app acceptance.

| Case / procedure | Expected | Current evidence | Status |
| --- | --- | --- | --- |
| Main + two mock notes | Three independently identified ordinary windows; opening the same ID reuses it | Trace at 05:38:55 UTC contains IDs 1/2/3; repeated open events reuse them, never add a fourth | Runtime pass |
| Mock boundary | Clear validation-only/no-saving labels; temporary probe is not note editing | Native accessibility tree and rendered Main window show validation-only/no-saving disclaimer and temporary probe label | Automated UI pass |
| Registry / activation | Regular from first open until final close, including minimized windows | 05:38:47 regular with Main; 05:39:40 closes retain regular; 05:39:41 last close switches accessory; reopening switches regular. Final build at 05:58:28–30 has all three minimized while typing/Escape leaves policy regular | Runtime pass (including minimized windows) |
| Full-screen, all open | Physical Option+Space/type/Escape; no Space jump or unrelated-window raising; origin receives typing after Escape | Beam confirmed the eight-step Notes full-screen procedure: “Yes, all worked” (hello in Hana, Escape then back in Notes, no Space jump or unrelated windows) | User-observed pass |
| Full-screen, all minimized | Same invocation/typing behavior while all three remain minimized | Beam: “Yes, all passed” to minimized Command-Tab/full-screen invoke/type/Escape with no Space jump or window reappearance; trace corroborates three minimized IDs | User-observed + runtime pass |
| Dock / Command-Tab | App remains reachable with open or minimized windows; Dock opens Main only | Beam confirmed minimized Command-Tab and “Yes, only Main returned” from Dock; 05:58:40 restores ID 1 only while IDs 2/3 remain minimized | User-observed + runtime pass |
| Destination from bar | ⌘2 opens/focuses Mock Note A; immediate physical typing reaches its probe without click or stale restoration | Original request failed; ordering-only candidate failed. Explicit activate(from:options:) passed: Beam confirmed automatic Space switch and typing into Note A; request allowed and key event traced at 05:53:45 UTC | User-observed pass after fix and on final build |
| Owned-origin Escape | Invoke from a working-window probe; Escape returns typing to that same probe | Final build: Beam answered “Yes, both passed” to destination typing followed by invoke/type/Escape and no-click typing back into the same probe | User-observed pass |
| Last close / repeated transitions | Accessory only after last close; menu Search and global invoke/type/Escape still work; close/reopen and rapid Escape/reinvoke stay stable | Final build: Beam confirmed last-close global invoke/type/Escape and menu Search, rapid reopen/reinvoke, and outside-click typing; trace shows accessory with empty registry, new sessions and later regular on reopen | User-observed + runtime pass |
| Single yellow button | Native animation goes to Dock | Final build: Beam reported “At the Dock” after clicking Main’s native yellow button | User-observed pass |
| Bulk minimize | All three animate to Dock and stay registered | Beam: “Yes, all three” to bulk animation endpoints at Dock | User-observed pass |
| Close all → reopen three → bulk | Same Dock endpoints across policy transitions | After clarification to use the normal desktop with all three visible, Beam: “Yes, both passed” for Command-Tab presence and every animation ending at the Dock | User-observed pass |

## Human observations

- Open-windows full-screen check: Beam followed eight explicit steps opening Main/A/B, entering native full-screen Apple Notes, invoking Option+Space and typing `hello`, then Escape and typing `back` without clicking. Beam replied **“Yes, all worked”** to the question naming both typing destinations, no Space jump, and no unrelated Hana windows appearing. This is physical evidence; it does not yet cover minimized windows or destination opening.

- Destination / owned-origin sequence: Beam answered **“No — I’ll describe what happened”** to the six-step physical check (Option+Space → ⌘2 → type into Mock Note A; then invoke/type/Escape → type back into its probe). Beam subsequently isolated the first half: ⌘2 closes the bar but stays in full-screen Notes, where typing continues. After manually swiping out, Note A is on the destination desktop; if Codex was active before entering Notes, Note A briefly appears in front then falls behind Codex. If Hana was active before entering Notes, Note A is focused after manually leaving full screen. No case automatically switches to the destination. Owned-origin Escape has therefore not yet been exercised. At 05:43:14 and 05:43:48 UTC, the trace records `dismiss.destination` then `working.open` for ID 2 while Notes is still frontmost, with no subsequent `working.becameKey` event in that interval. These synchronous states narrow investigation but do not diagnose a cause.
- A focused human-assisted reproduction command is available: `bash scripts/validation/destination-focus-loop`. After the precise report, the script recorded Beam’s observation as `DESTINATION_FOCUS=fail`, exit 1. This is a human verdict from the repeated physical runs, not an unattended keyboard test. The first controlled candidate changed only destination ordering: make the requested window key/front before requesting activation. Beam reported “No — it stayed in Notes”; the loop returned exit 1 again. The trace at 05:51:57 UTC shows Hana inactive before/after the request and all three working windows outside the active Space. The second candidate restores the original ordering and uses `NSRunningApplication.current.activate(from:options:)` with the current frontmost source, recording the request-allowed result. Beam reported **“Yes — switches and types into Note A”** on the same Codex → full-screen Notes → Option+Space → ⌘2 procedure. The loop returned `DESTINATION_FOCUS=pass`, exit 0. At 05:53:45 UTC the explicit request was allowed and followed by Note A becoming key with Hana frontmost. The user observation, not these flags, establishes the Space switch and typing. The retained fix names the frontmost source in the activation request; ordering is unchanged from the initial implementation. Temporary `DEBUG-issue4` source instrumentation was removed; the final build retains a content-free `working.activation-request` acknowledgment event. Historic diagnostic traces remain labeled as such.

No automated test was added to claim this native activation fix. The existing unit boundary cannot reproduce a foreign full-screen app or actual physical keyboard routing; an assertion on activation acknowledgment or responder flags would miss the reported bug. The checked-in human-assisted loop is the regression procedure. API semantics were checked against the current SDK and Apple’s [activate(from:options:) documentation](https://developer.apple.com/documentation/appkit/nsrunningapplication/activate(from:options:)); this evidence establishes the tested behavior, not a general WindowServer root cause.

- Final candidate (startup 05:54:23 UTC, CDHash above): Beam repeated full-screen Notes → ⌘2 → immediate destination typing, then invoked from Note A’s probe, typed, escaped, and typed back in the same probe without clicking. Response: **“Yes, both passed.”** Beam then clicked Main’s yellow button and reported its animation ended **“At the Dock.”**

- Minimized-window final-build checks: Beam confirmed **“Yes, all three”** animations went to the Dock; **“Yes, all passed”** for Command-Tab presence and full-screen invoke/type/Escape with no Space switch or window reappearance; and **“Yes, only Main returned”** after clicking the Hana Dock icon. Traces at 05:58:28–30 UTC show typing and Escape with all three minimized and policy regular. At 05:58:40 UTC, only Main is deminiaturized and both note IDs remain minimized.

- Final last-close/rapid checks: Beam answered **“Yes, all worked”** to global invocation, immediate typing/Escape return and menu Search after closing all windows, and separately **“Yes, all worked”** to rapid fresh reopen/same-session reinvocation and outside-click typing in Notes. At 06:01:25–26 UTC the trace shows invocation/outside-click with an empty registry and accessory policy; at 06:01:40 UTC Main reopening restores regular policy.

- Final close-all/reopen/bulk check: after closing all, reopening Main/A/B, and returning to the normal desktop with all three visible, Beam confirmed **“Yes, both passed”** for Hana appearing in Command-Tab and all three animations ending at the Dock. This completes the third animation procedure separately from the earlier single and bulk observations. No top-left endpoint recurred in this build; the earlier prototype report remains unexplained.

## Reproduction procedure

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

Independent standards review, repeated through `d71eee7...2a56ceb`: **0 findings**. Main-actor Mac Interaction ownership, AppKit controllers, typed validation destinations and evidence separation conform to the repository rules. No actionable baseline smell was reported.

### Spec

Independent spec review, repeated through `d71eee7...2a56ceb`: **0 code defects**, **0 scope-creep findings**, **1 acceptance-evidence gap**. At the time of review, the finding covered the still-pending physical checks. The final-build human observations and runtime matrix above now complete those gates; no passing conclusion is inferred from state flags.

Final independent evidence follow-up on `a1bc57d` confirmed all #4 criteria are covered with no material overclaim. Review totals: Standards **0** findings; Spec **0 open findings**, with **1 prior acceptance-evidence finding resolved** by the completed physical checks. No remaining implementation or scope finding.

## Remaining limitations

All scoped #4 core acceptance checks are complete on the tested Mac, including final-build destination focus. PR #12 can be ready for review; it is not merged. This does not complete parent milestone #2. Candidate-based IME testing remains explicitly deferred for current English/Thai use. Focused-window AX placement, display disconnect, lock/sleep, Stage Manager and other full-screen apps are unverified. No persistence, real note editing, organizer or search results were added. Builds, screenshots, launch acknowledgment and responder flags are not focus proof.
