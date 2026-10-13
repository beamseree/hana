# Issue #3 validation — 2026-10-13

Implementation branch: `codex/issue-3-native-shell`; review baseline: `fe9681ce96c141d7d10ece6aaff8d01b7ab9cbc7`. This is the native empty Search shell only. Prior prototype passes are not counted as current app acceptance.

## Environment and identity

- macOS 26.4.1 (25E253), arm64; one attached screen reported at current startup (the earlier prototype had three).
- Selected `/Applications/Xcode-26.6.app/Contents/Developer`; Xcode 26.6 (17F113), Swift 6.3.3, SDK 26.5; first-launch status succeeded. No toolchain installation/change.
- Installed `~/Applications/Hana.app`, identifier `com.beamseree.hana`, version 0.1.0 (1).
- `security find-identity -v -p codesigning`: 0 valid identities. Signature=adhoc, TeamIdentifier not set, no entitlements, no sandbox, no hardened runtime. Strict signature/plist checks passed.
- Initial physical-test build CDHash: `0a4ea506fe151bbfa073cee53e0e503423852619`. Final reviewed build CDHash: `6388141c154d0e566a329da0c18a937651d94d6e`; designated requirement is that code hash. The intervening fix narrows notification cleanup to preserve editor diagnostics after dismissal; panel/focus behavior was unchanged. Ad-hoc signing does not promise permission continuity after rebuild.
- No privacy grant, shortcut preference, or Spaces setting was changed. The previously running preserved prototype was terminated before normal Hana launch to free Option+Space; its files were read via Git objects and never modified. Its Git branch was not checked out here.

## Automated behavior checks

TDD at the agreed Mac Interaction boundary:

- `reinvocationKeepsTheCurrentSession`: initially failed to compile before Mac Interaction existed, then passed against real AppKit.
- `oldDismissalCannotCloseAReopenedBar`: failed because the old invocation cleared the new session; passed after enforcing invocation identity. Covers dismissal, fresh identity and stale callback rejection through the production module interface.
- Final `xcrun swift test`: **2 Swift Testing tests passed**, 0 failures (0.190 seconds); the separate XCTest compatibility header reports 0 XCTest tests. Debug compile/typecheck, release build, shell syntax, plist lint and strict signature checks passed.
- Native focus is deliberately **not** asserted by either test. They do not simulate a physical keyboard or certify full-screen placement.

## Running-app evidence

The [content-free runtime capture](runtime.jsonl) retains both physical-test sessions and controlled conflict/editor checks. It contains app bundle identities and geometry, but no query text or filenames. These state traces corroborate observations; they do not independently prove physical routing or full-screen state.

| Case | Evidence | Result |
| --- | --- | --- |
| Launch installed signed app | Launch Services launched `~/Applications/Hana.app`; startup reports accessory policy, hidden panel, level 3, exclusive shortcut OSStatus 0 | Runtime pass |
| Normal physical invoke/type/Escape | Beam was asked to invoke from a disposable foreign input, immediately type `- [ hello`, Escape, and type back in the original field | Beam: **“yes for both”**, answering separate normal/full-screen procedure; user-observed pass |
| Full-screen physical invoke/type/Escape | Same explicit sequence over another app's native full-screen Space with no working windows; no unwanted Space change | Same user confirmation; full-screen state and return typing are human evidence, not independently probed |
| Outside click and typing in clicked app | Beam was asked to click another app and type there | Beam: **“yes for all”** to the explicit combined procedure; user-observed pass; four outside-click dismissals traced in initial capture |
| Reinvoke retains query; dismiss/reopen is empty | Beam confirmed the combined procedure; one session retained 14 UTF-16 units through four reinvocations; subsequent new session had zero | User-observed pass + trace; automated identity test separately passes |
| Menu invocation | Explicitly included in Beam's combined procedure | User-observed pass |
| Exclusive shortcut conflict + menu fallback | Separate fixture successfully reserved Option+Space; Hana startup returned `-9878` (`eventHotKeyExistsErr`). Beam was asked to inspect “Hana !”, unavailable message, and invoke/type through Search | Beam: **“Warning visible and menu Search works”**; runtime + user-observed pass. Fixture then stopped and normal registration restored |
| Empty native surface | Automation attached once Beam left Search visible. Accessibility tree contained one scroll area and one Search text input; rendered capture showed opaque white input surface without labels/results | Automated UI inspection; no keyboard-focus inference |
| Literal punctuation / English | Targeted native UI typing produced exact `- [ hello `; physical procedure also included these symbols | Automated native editor + user-observed evidence |
| Thai paste, native undo/redo/selection | Targeted paste produced `- [ hello สวัสดี`; Cmd-Z removed the Thai paste, Cmd-Shift-Z restored it, Cmd-A selected the full string | Automated native editor pass. Tool's direct Thai `typeText` did not insert Thai; paste did. This alone is not physical Thai-input-source evidence |
| Native context menu | Right-click showed native text menu. Escape closed the menu, keeping selected text and Search visible | Automated native editor pass; candidate-based IME remains deferred |
| Pointer-display placement | Runtime bar `{426,785,660,64}` within visible frame `{0,0,1512,949}`; screenshot inspected | Runtime containment + rendering; physical follow-up below. Multiple/negative-coordinate displays currently unavailable |

Initial capture has nine fresh presentations (first 48.88 ms; subsequent eight 6.85–15.02 ms) and four same-session presentations (0.30–0.62 ms). These are synchronous presentation-call timings with diagnostics enabled, **not** physical shortcut-to-typing latency or an established p95 budget. No cold-process launch timing claim is made.

The UI automation tool initially timed out attaching to the app while no ordinary window was open; after Beam left the bar visible it attached successfully. The physical global shortcut tests were performed by Beam. Build/signature success, a screenshot and `editorResponder` were never substituted for keyboard evidence.

## Final-build follow-up

After the conflict fixture stopped, the installed reviewed build was relaunched with diagnostics and registration status 0. Beam was asked to recheck full-screen outside-click typing, pointer-display containment and physical Thai input. Result pending at the time of this draft.

## Standards review

Independent standards reviewer: no actionable documented-standard violations or baseline code smells in `fe9681c...e2295a2`. Native ownership, ADR 0002/0004 boundaries, real AppKit session tests and separation of evidence were consistent with repository instructions. Supplemental review of the conflict fixture and instructions also found no actionable concerns.

## Spec review

Independent spec reviewer: no substantive implementation defect or scope creep in `fe9681c...e2295a2`. One acceptance-evidence gap was noted: the conflict runtime check and stale Pending documentation. The conflict check subsequently passed as recorded above, and this report incorporates Beam's observations. No unrelated ticket was implemented.

Review totals: Standards **0 findings**; Spec **0 implementation findings**, **1 evidence gap resolved**. No remaining implementation finding on either axis.

## Remaining scope and limitations

Candidate-based IME verification is deferred by Beam. AX focused-window placement, display hot-plug, lock/sleep and Stage Manager are unverified. Multi-display/negative-coordinate placement could not be repeated because only one screen was attached. There are no working windows to minimize in #3; the prototype's unreproduced top-left minimize observation remains recorded in #1 and ADR 0005 without claiming a fix. No architecture ADR is promoted to accepted by this shell build. Public signing/notarization and permission continuity are not claimed.
