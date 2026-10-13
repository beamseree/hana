# Minimize animation investigation — 2026-10-13

Reported symptom: bulk minimization animated toward the top-left menu area instead of the Dock. This is a visual endpoint bug; `isMiniaturized` cannot establish its absence.

## Feedback loop

`minimize-loop.sh` is adapted from the diagnosing-bugs skill's human-in-the-loop template. It prints the exact UI action and accepts the user's observed endpoint. `top-left` exits 1, `dock` exits 0, and `unclear` exits 2. The agent runs it; the human observes the native animation and answers in chat, and that answer is supplied to the waiting process. This is a human-assisted visual check, not an automated animation assertion.

No system settings or window/focus implementation were changed during these comparisons. The current process was launched after the earlier prototype session; its only source change since the first report was reducing diagnostic key logging. Thus a passing retest is not evidence that a code fix corrected the original report.

| Comparison | Exact command / action | Observation | Result |
| --- | --- | --- | --- |
| One ordinary window | `bash debug/minimize-loop.sh single`; open Main through WF, click yellow button | Beam: “Toward the Dock” | PASS, exit 0 |
| Original bulk path | `bash debug/minimize-loop.sh bulk`; open Main, Note A, Note B, choose WF → Minimize all working windows | Beam: “No, all go toward the Dock” | PASS, exit 0 |
| After closing last window / reopening | Close all; immediately reopen all three and bulk minimize | Beam subsequently replied: “Yes, all go to the Dock” | PASS, user observation; reply arrived after waiting script was cancelled |

Runtime logs corroborate the single-window minimizations and bulk operation. The bulk operation at 04:09:08 UTC is followed by Note A, Note B and Main becoming minimized through 04:09:10; activation policy stays regular. Human observation establishes the Dock endpoint. Neither screenshots nor state logs were substituted for that observation.

## Finding

The original symptom has not reproduced in the completed controlled checks. The native yellow-button path, unchanged bulk path, and close-all/reopen/bulk sequence all animated toward the Dock in the user-observed checks. There is no established root cause and no verified fix. Without a failing reproduction, changing policy timing, adding delays, suppressing animation, restarting the Dock or splitting processes would be speculative. No such changes were made.

The original report remains a known intermittent observation. On recurrence, first capture the exact trigger, which display contains the window/Dock, whether the app just entered regular activation, and whether a single yellow-button minimize also fails. Repeat the same loop while the failing state still exists, before restarting the prototype. A short recording would help distinguish the animation endpoint from cross-display travel.

## Scope

Beam explicitly deferred candidate-based IME tests because current use is English and Thai. Deferred means unverified, not passed. This no longer blocks the current prototype. The single-process recommendation remains supported by the prior full-screen, Dock/Command-Tab and lifecycle checks.

## Primary references

Apple describes [miniaturize](https://developer.apple.com/documentation/appkit/nswindow/miniaturize(_:)) as moving the window into its minimized Dock representation. [performMiniaturize](https://developer.apple.com/documentation/appkit/nswindow/performminiaturize(_:)) models the standard button action. [setActivationPolicy](https://developer.apple.com/documentation/appkit/nsapplication/setactivationpolicy(_:)) reports whether changing policy succeeded; it does not certify an animation destination. Checked on 2026-10-13. These descriptions do not diagnose this unreproduced symptom.

Diagnostic source unchanged: `git diff -- Sources.swift Info.plist` returned no changes during the investigation. No rebuild was necessary for documentation and the observation script.
