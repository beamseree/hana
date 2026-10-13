# Window/focus experiment — evidence report

2026-10-13, macOS 26.4.1 (25E253), arm64. Xcode 26.6 (17F113), Swift 6.3.3, macOS SDK 26.5. One process; panel level `.floating` (3). Three attached displays. Prototype Accessibility trust: false. No privacy grants, shortcut preferences, or global display/Spaces settings changed.

## Evidence vocabulary

- **Documented**: Apple describes the individual capability; this is not a combined behavior guarantee.
- **Automated check**: build/signature/plist inspection or native accessibility-tree inspection.
- **Runtime trace**: events produced by the running application. State flags alone cannot prove physical keyboard routing, visual stacking, or lack of Space movement.
- **User observed**: Beam used the real keyboard and desktop and reported the outcome in this chat. A broad confirmation has less diagnostic detail than a per-case recording.
- **Untested / pending**: no reliable observation; never silently counted as pass.

## Current matrix

| Case | Expected | Observed result and evidence | Status |
| --- | --- | --- | --- |
| Toolchain and bundle | Reproducible native build without toolchain changes | Selected directory/version/SDK/host matched; first-launch check, Swift 6 build/typecheck, plist lint, strict ad-hoc signature verification passed | Automated pass |
| Startup / shortcut registration | Accessory, menu item, exclusive Option+Space | Handler and registration OSStatus both 0; runtime started with zero working windows and accessory policy | Runtime pass; registration alone is not delivery proof |
| Normal app, no working windows | Invoke, immediately type, Escape back to origin without Space switch | Beam answered “yes it works” to this exact sequence. Trace sessions 4–5 recorded five UTF-16 units, native key events and Escape, with Figma workspace-frontmost throughout | User observed pass + trace |
| Full-screen app, no working windows | Bar visible and editable over full screen; no Space jump | Beam reported “yes seems to all be working” to the two-state full-screen procedure | User reported pass; no recording or independent foreign full-screen-state probe |
| Full-screen app, working windows open | Same typing behavior; no unrelated working windows raised; Dock and Command-Tab remain | Same user confirmation to explicit full-screen + Dock/Command-Tab procedure. Trace independently confirms regular activation after Main opens | User reported pass; full-screen state and Dock/Command-Tab visibility are user evidence |
| Multiple ordinary windows | Main and two separate mock notes coexist | Runtime registry contains Main, Note A and Note B simultaneously; native AX inspection confirmed ordinary Main/editor | Runtime pass |
| All working windows minimized | Remain regular; keep Dock/Command-Tab and full-screen invocation | Session 7 invoked over Arc with all three windows marked minimized and policy regular; Escape reached the native editor (no text was entered in that session). Beam subsequently confirmed the dedicated minimized/full-screen/Dock/Command-Tab procedure works | User reported pass + lifecycle trace; minimized typing not independently traced |
| Closing last working window | Accessory; WF and Option+Space remain usable | Trace records sequential close of all three minimized windows; policy stays regular until final close, then accessory. Sessions 8–9 delivered hotkeys after close | User reported pass + runtime trace |
| Open working window from bar | Hide capture; open/activate intended window; no return to old origin | Beam confirmed opening Note A directly from the bar receives focus. Working-window creation/activation events are traced, but that exact Note A destination sequence was not independently isolated | User reported pass |
| Outside click | Discard; clicked app keeps typing focus | Beam confirmed clicking another app and typing works. Trace records global outside-click dismissal and clears text, including a later click to Codex without reactivating Arc | User observed pass + trace |
| Repeated invocation | Preserve same session/text; refocus editor | Session 16 retained a nonempty buffer through repeated hotkeys (`invoke.existing`); earlier repeats also stayed in the same session | User reported pass + runtime trace |
| Rapid Escape/reopen | New session; no stale dismissal/focus callback | Sessions 10–17 repeatedly invoked, entered text and dismissed; no old-session dismissal appeared after a new invocation | User reported pass + runtime trace |
| Native selection / expansion | Preserve selected range and editor identity | Beam answered “works” to the selection/expansion procedure. Editor identity is preserved in code; the log does not contain an isolated morph event in this run | User reported pass; expansion lacks independent trace |
| Native marked-text composition | Candidate UI and first Escape do not discard capture | Final capture contains one `setMarkedText` in session 26, followed by successful insertion; Escape came after marked text cleared. This proves one brief composition/commit only. Enabled-source inspection showed U.S. plus system palettes; no Japanese/Chinese source was added | Partial runtime evidence; candidate UI and Escape during composition deferred by Beam on 2026-10-13 (English/Thai use) |
| Display placement | Focused display if available; pointer fallback otherwise | Three screen frames recorded: primary 1512×982 at (0,0), upper-right 2560×1440 at (753,982), upper-left 2560×1440 at (-1807,982); pointer fallback active. Sessions 18, 19 and 20 placed the bar on upper-left, upper-right and primary displays respectively, using pointer fallback | User reported pass + runtime placement trace |
| Focused-window AX placement | Bounded geometry query with fallback | Prototype is not AX-trusted; no permission request made | Untested |
| Context menu / candidate-window click | Keep capture while interacting with owned text UI | Conservative menu/composition guards exist; native behavior not yet established | Untested |
| Sleep/lock, display disconnect, other full-screen apps/Stage Manager | Avoid stranded panel or unwanted focus | Sleep/display-change hooks exist; these environments were not exercised | Untested |

## Primary documentation checked

Checked current Apple pages and the selected macOS 26.5 SDK, rather than treating the design flags as a proven recipe:

- [Nonactivating panel](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel): panel presentation does not activate its owning application by definition.
- [Regular activation](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/regular) and [accessory activation](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory): Dock presentation differs; changing policy does not itself prove Command-Tab behavior.
- [canJoinAllApplications](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications): eligible windows can join other apps' full-screen Spaces; mutually exclusive with `.primary` and `.auxiliary`. Neither conflicting flag is used here.
- [Panel key behavior](https://developer.apple.com/documentation/appkit/nspanel/becomeskeyonlyifneeded): input-view key eligibility matters. The editor explicitly permits key focus.
- [Event monitoring](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html): local and global monitors cover different event streams; global monitoring cannot suppress foreign events. This harness monitors global mouse events only and leaves them intact.
- Selected SDK `AppKit.framework/Headers/NSWindow.h` describes active-Space membership as window state. `Carbon.framework/Frameworks/HIToolbox.framework/Headers/CarbonEvents.h` documents exclusive `RegisterEventHotKey` registration and main-thread use. No Accessibility permission was needed to register/deliver the shortcut here.

## Recommendation

Continue with the single-process candidate; no concrete failure has justified the accessory-helper fallback. Initial physical tests support full-screen invocation at `.floating` while preserving regular-app access. The user confirmed the minimized/multiple-window and lifecycle checks. Keep ADR 0005 proposed pending clarification of the minimize-animation anomaly; candidate composition/Escape testing is deferred by Beam for English/Thai use; this is a supported next direction, not complete production acceptance. Do not increase the level to cover up a failure.

If a reproducible native failure emerges, record exact origin app, full-screen state, working-window count/minimization, activation policy, trigger and log sequence. Change one candidate flag or focus action at a time. Only then compare a minimal accessory helper with an ordinary regular process. A helper should not be inferred necessary from the UI automation tool failing to deliver the global shortcut.

## Automation limitation

The native UI tool timed out when binding apps with no ordinary window, though the prototype process launched and logged successful registration. Sending a targeted Option+Space through Finder produced no `hotkey.received` event. That does not prove system shortcut failure: subsequent physical Option+Space did produce events and editor input. We switched to user-driven keyboard/full-screen checks. The ordinary Main window and native editor were later visible through the accessibility tree.

## Next implementation step

Completed single-window, bulk-minimize and close-all/reopen/bulk comparisons all animated to the Dock; see [investigation](debug/MINIMIZE-INVESTIGATION.md). Preserve the original report for reproduction if it recurs. Beam deferred candidate-based IME testing on 2026-10-13 because current use is English and Thai. Then extract the proven Mac Interaction behavior into a small production interface for presentation, reasoned dismissal and destination opening. Keep registry, activation transitions, origin tracking and display selection local to that module. Do not add search, storage, helper coordination or the organizer to this experiment. Candidate-based input remains an explicit future compatibility test, not a gate for the current English/Thai prototype.

## User-observed minimize animation anomaly

Beam reported that “Minimize all working windows” animates the windows one by one toward the top left of the menu area. Sequential calls in the harness explain the one-by-one sequence; they do not explain the destination. The implementation calls `NSWindow.miniaturize(nil)` and supplies no custom animation or target. Apple's [miniaturize documentation](https://developer.apple.com/documentation/appkit/nswindow/miniaturize(_:)) describes minimizing to the Dock, so the top-left destination is not accepted as intended product behavior. The trace confirms all three became minimized while policy stayed regular, and Beam confirms access/invocation continued to work.

Cause remains undiagnosed. Do not label it an OS bug, an activation-policy defect or a reason to split processes without reproduction. The [follow-up investigation](debug/MINIMIZE-INVESTIGATION.md) tested the single yellow button, original bulk path and close-all/reopen/bulk sequence: all animated to the Dock without changing the window implementation. The original symptom is not currently reproduced; no root cause or fix is established. Do not change Dock/Spaces settings or suppress animations to hide it.

## Evidence capture

`evidence/` contains environment checks, sanitized runtime snapshots and this chat's user-observation record. Earlier diagnostic key codes are reduced to Escape-versus-other before capture; editor text is never included. Broad user confirmations are retained as such, without inventing measured latency, candidate-input results, or window-server evidence. The final source changes only diagnostic key logging after the interactive run; no focus/flag behavior changed.
