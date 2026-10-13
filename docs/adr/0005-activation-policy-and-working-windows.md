---
status: proposed
---

# ADR 0005 — One process with activation policy following working windows

**Accepted experience, 2026-10-13:** Beam requires Dock and Command-Tab access while working windows are open; this explicitly replaces the earlier menu-bar-only answer. Global invocation and menu-bar access remain available after those windows close.

**Proposed implementation:** use one process, accessory activation when no working windows are open and regular activation while any main, note or Settings window is open, including minimized windows. This avoids extra process coordination, but is unresolved until a native prototype proves that the nonactivating bar can still take typing focus over another app's full-screen Space while this app has working windows and Dock presence.

If that test fails, evaluate a dedicated accessory bar helper and a regular organizer process, with one collection-writing authority and a narrow XPC interface. That adds launch/reconnection, signing, save acknowledgment and recovery coordination, so it should follow evidence rather than be built preemptively. Do not trade away Dock access, force a Space switch or raise the bar above all system UI merely to retain one process.

**Resolution gate:** run phase 2 of the [technical design](../technical-design.md), record the OS/build and both activation states, then accept or supersede this ADR. [Apple activation policy](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/accessory) and [full-screen eligibility](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications) describe capabilities; they do not settle this app's combined behavior.

## Prototype evidence — 2026-10-13

An [isolated runnable AppKit experiment](https://github.com/beamseree/hana/blob/prototype/window-focus/prototypes/window-focus/README.md) now exists. Swift 6 build and ad-hoc signature checks passed on macOS 26.4.1. Exclusive Option+Space registration succeeded. The user confirmed invocation, typing and Escape back to the origin in accessory mode; runtime events corroborate native text insertion while the foreign app remains workspace-frontmost. Subsequent user-driven checks reported full-screen invocation working in both activation states with Dock/Command-Tab access retained, including minimized windows. Traces corroborate all three registered windows remaining in regular policy when minimized and switching to accessory only after the last closes; reinvocation and three-display pointer placement were observed.

The [test matrix](https://github.com/beamseree/hana/blob/prototype/window-focus/prototypes/window-focus/TEST-MATRIX.md) distinguishes documented capability, runtime state and interactive observation. Recommend continuing with one process at floating level; no concrete full-screen/Dock conflict has justified the helper fallback. The follow-up [minimize investigation](https://github.com/beamseree/hana/blob/prototype/window-focus/prototypes/window-focus/debug/MINIMIZE-INVESTIGATION.md) could not reproduce the top-left animation in single-window, bulk or close-all/reopen/bulk checks; all went to the Dock with unchanged window code. Keep the unexplained original report explicit and this ADR proposed rather than claiming a verified cause/fix. Beam explicitly deferred candidate-input/active-composition Escape testing on 2026-10-13 for current English/Thai use; it remains unverified, but is no longer a gate for this prototype. The main architecture gate has positive user evidence, but full production acceptance is not established. Some broad user confirmations lack an isolated trace; see the matrix. No helper, extreme overlay level, privacy grant or global Spaces-setting change was needed.


## Integrated milestone evidence — issue #10

The merged app retains one nonactivating panel at `.floating`, accessory activation with zero working windows and regular activation while any remain open/minimized. PR #17's bezel/card design is preserved. The [integrated assessment](../evidence/issue-10/validation.md) separates current automated checks, native traces and physical observations from prior prototype/#9 evidence and unavailable cases. Status remains proposed; recorded native state is not physical focus proof.

The concrete integration defect diagnosed in #10 was synchronous Spotlight type-attribute fetching on the input actor. It was addressed within the existing Search adapter and does not justify a helper process. No cause or fix is claimed for the original unreproduced top-left minimize animation or #8's earlier nonreproducing foreign-input failure. Candidate IME stays deferred; unresolved environmental and physical performance gates remain explicit in the integrated report.

Current #10 human checks now confirm all six normal/full-screen and zero/open/minimized working-window combinations, Dock/Command-Tab and close/reopen/minimize transitions, plus editing and three-display placement. This strengthens the one-process evidence without resolving physical latency measurement or all integration acceptance gates. Later debug timing misses and a successful bounded release rerun are both retained in the report; neither proves a native lifecycle failure requiring a helper.

Issue #10’s [timing follow-up](../evidence/issue-10/timing-followup/validation.md) corrects the regression metric to AppKit main-queue enqueue delay; it passes while still detecting the original metadata defect. This retains the single-process implementation unchanged and does not establish a physical latency guarantee or justify a helper. Historical sleep delays remain recorded. Status remains proposed pending integrated acceptance; the original minimize anomaly remains unreproduced with no established cause/fix.

Beam's 2026-10-13 [physical timing deferral](../evidence/issue-10/validation.md#physical-timing-deferral--2026-10-13) permits PR #19 to move to review with the numerical physical targets unmeasured. This is an explicit acceptance limitation, not new architecture evidence or acceptance of this ADR. Status remains proposed; historical observations and untested environmental cases remain unchanged.
