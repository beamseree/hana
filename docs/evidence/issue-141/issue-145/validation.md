# #145 — Block the automatic switch for calculations

Validated on 2026-10-16 on macOS 26.4.1 (25E253), arm64, Apple Swift 6.3.3. Implementation starts at `e3d52b9`; the native fixture Store correction is `e77c660`. Final tested source: `6925380b2384d7d70c29a47a297afde69b53fae9`, merging integration `b62412688b6bd0101574dd530f11ef6a37b02c58` (#143) without conflicts. The native testing slot was explicitly granted for disposable fixtures.

## Automated evidence

- Pure gate/policy/Debug/tricky-input checks passed: **20 tests in 4 suites**, 0.037 seconds, exit 0. All test commands compile Swift sources and fixtures. Raw [pure log](pure-tests.log).
- New native fixtures passed: **4 tests in 1 suite**, 6.078 seconds, exit 0. Their parameter cases cover all four firing strategies and eight non-value calculation expressions. Raw [native log](native-tests.log).
- Targeted automatic-switch/Debug/submission/Word-paced native and policy regressions passed: **169 tests in 21 suites**, 22.158 seconds, exit 0. Raw [automatic-switch log](automatic-switch-tests.log). The initial full-suite failure and isolation are preserved below.
- Final `xcrun swift test --no-parallel` on the merged source passed **635 tests in 93 suites**, **107.772 seconds**, **exit 0**. **11 existing live-index tests were environment-gated skips**; no live-index coverage is claimed. Raw [full log](tests.log), [captured result](test-result.json).
- [Initial red evidence](red-evidence.log) was the missing Calculation gate reason at the agreed public gate boundary. The first native fallback fixture omitted a Store, so ordinary text correctly remained blocked by collection unavailability; adding a disposable Store corrected the fixture without changing product behavior. The [initial failed native log](native-initial-failed.log) is retained and is not a pass.
- Independent [two-axis review](code-review.md) at `e3d52b9`: Standards **0 findings**, Spec **0 implementation findings**. Both axes reviewed the fixture-only correction and merged #143 compatibility at `6925380`, again with **0 findings**.

## Acceptance mapping

| Requirement | Evidence |
| --- | --- |
| Calculation blocks before every other reason, including every recognized state | `everyRecognizedCalculationBlocksBeforeOtherReasons`: value, trailing operator, unclosed group, function without argument, division by zero, undefined function, too-large power and malformed expressions; exact result and unavailable Collection cannot replace Calculation. Independent recognition does not require an evaluable value. |
| Ordinary words restore existing rules | `anOrdinaryWordRestoresTheExistingGateRules`: normal allowance, strong application match and unavailable Collection behavior. `addingAWordRestoresClassification` covers all firing strategies. Native `addingAWordRestoresSuggestionsAndTheClassifier` verifies suggestions and the scripted request. |
| No classifier requests, including Word-paced; Debug shows Calculation | `calculationsNeverRequestClassificationOrQueueASave` covers all four firing strategies and nine expressions at edit/tick/submission boundaries; native `nonValueCalculationsRemainBlockedInTheDebugFooter` covers eight non-value expressions. `enterCopiesImmediatelyWhileSourcesLoadWithoutClassifyingOrSaving` checks no scripted request after the longest firing delay. |
| Selected answer Enter copies and closes immediately, with no save | `enterCopiesImmediatelyWhileSourcesLoadWithoutClassifyingOrSaving` records exactly `400`, synchronous dismissal while both sources load, and an empty fixture Collection for every firing strategy. `replacingAQueuedSubmissionWithACalculationCopiesWithoutALateSave` starts a real pending scripted decision/Enter intent, replaces the text, copies immediately, then verifies no item was saved after a late reply. |
| Existing automatic-switch behavior and full-suite compatibility | Targeted automatic-switch/native regression run passed 169 tests in 21 suites; final full serial rerun passed 635 tests in 93 suites with 11 live-index skips. |

## Limits

All classification is scripted and all Stores/defaults/diagnostic logs are disposable. No app install, real provider request, permission change or system setting change was performed. Injected copy and fixture commands do not establish physical foreign-app focus, perceived latency, provider accuracy or pasting into the invocation origin. #146 remains open for that human trial. #141 is not closed by this child evidence.

## Initial full-suite failure and isolation

The first full run at `6925380b2384d7d70c29a47a297afde69b53fae9` completed with **635 tests in 93 suites**, **119.927 seconds**, **1 issue**, **exit 1**, and 11 environment-gated live-index skips. [Failed full log](tests-initial-failed.log), [captured result](initial-test-result.json). This is not a pass.

The only issue was `MainNoteOrganizationTests.noteMenusActOnSelectionAndHaveKeyboardEquivalents`: its signed native child exited 1 at `menu-archive-empty` (zero stored archived notes). The unchanged exact test passed in [isolation](isolated-note-menu.log): **1 test in 1 suite**, **4.085 seconds**, **exit 0**, child SHA-256 `73e762055c43e636c8bfa2299670983f0298506314db3b41c7b060937259301f`. No cause or product fix is claimed.

A bounded full serial rerun at the exact same source passed **635 tests in 93 suites**, **107.772 seconds**, **exit 0**, with the same 11 live-index skips. The note-menu child passed in that run with SHA-256 `3e98ba3a52b4c30c063e1f3db37de18e25aea11207402a883031260ddad1f3a1`. No source or assertion changed between the failed run, isolation and passing rerun. The native testing slot was released after the passing process exited.
