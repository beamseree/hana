# #143 — Explain calculations without an answer

Validated on 2026-10-16 against source `e1f1e0c64792bc2c30ba0038d6b2c76c271beb04`, based on integration `aaef64fd27f78b83d0c974662f425ceed0a4e678`. Host: macOS 26.4.1 (25E253), arm64, Apple Swift 6.3.3. Native fixture testing was explicitly granted. No app installation, real provider request, permission or system-setting change, or human foreign-app trial was performed. The native slot was released after the root-owned full run.

## Final automated evidence

- The root-owned `xcrun swift test --no-parallel` run passed **627 tests in 91 suites**, **108.059 seconds** for the suite, **112.268 seconds** process wall time, **exit 0**, on the source revision above. [Full log](tests.log), [captured process result](test-result.json).
- **11 existing live-index tests were environment-gated skips.** No live-index coverage is claimed.
- After the fixture adaptation, the focused calculator interactions, complete existing shortcut table and native note-menu fixture passed **10 tests in 3 suites**, **5.786 seconds**. [Targeted log](targeted-tests.log).
- Before removing two redundant standalone tests, the calculator/evaluator/suggestion run passed **22 tests in 3 suites**, **2.039 seconds**. [Calculator and suggestion log](calculator-and-suggestions.log). After cleanup, the unchanged parameterized evaluator coverage passed **6 tests in 1 suite**, **0.005 seconds**. [Evaluator log](evaluator-tests.log).
- `xcrun swift build` passed during implementation. Targeted and full runs also compiled the final Swift sources.
- Red/green slices used the pre-agreed Calculation text-plus-locale boundary and real Mac Interaction with fixture sources and a recording copy action. [Red excerpts](red-evidence.log) show missing incomplete answers, incorrect division wording, a function-name boundary, incorrect non-value defaults and explicit-selection loss on completion. Development logs remain under `/tmp/hana-issue-141-context/issue-143-evidence`.
- Independent [Standards and Spec review](code-review.md) finished with no outstanding findings. Both reviewers also cleared the final fixture adaptation.

## Acceptance mapping

| Requirement | Evidence |
| --- | --- |
| Answer owns state and exact wording | `calculationsWithoutAValueCarryTheirStateAndExactWording`: 18 cases for incomplete, division by zero and invalid, with exact title/subtitle and absent copy text. |
| Incomplete ends where invalid begins | Unclosed/trailing expressions remain incomplete; `3 + *`, `(3 + * 4`, `1..2`, `1 2 + 3`, extra/misplaced parentheses and malformed text before the end are invalid. Syntax takes priority over arithmetic failure: `5 / 0 +` is incomplete. Invalid subtitles preserve the text as typed. |
| Row first, no suggestions, first result default and Enter opens it | `answerWithoutAValuePrecedesResultsButDefaultsToOpeningTheFirstResult`, parameterized for all three states, verifies synchronous only-row selection, first position after results arrive, no suggestions, normal application opening and no copy. |
| Only-row selection and Enter dismisses like Escape without copy | `enterOnTheOnlyAnswerWithoutAValueDismissesLikeEscapeWithoutCopying`, parameterized for all three states, sends editor Enter while the source is loading, checks immediate dismissal and no copy, and verifies the owned origin panel's key status and original responder. |
| Completion selects a value unless user navigated | `completingACalculationSelectsItsValueUnlessTheUserNavigated` checks `12 *` to `12 * 4`, the exact value `48`, default answer selection, explicit result preservation, and both through late loading/finished file batches. |
| Existing basic behavior and suggestions retained | Existing evaluator arithmetic/locale/formatting tables and calculator/suggestion interactions pass, including value-copy Enter, real paste/editor copy, capture exclusion and suggestions returning when an ordinary word appears. |
| Documentation | Mixed Search's Calculation answers section records the state table, syntax boundaries, defaults, user-selection continuity and Enter behavior. |

## Failed and incomplete runs retained

The first full run on `79aa5659934fa0ed862ec5466db1d97bb1963b0f` completed with **627 tests in 91 suites**, **126.687 seconds**, **2 issues**, **exit 1**. [Failed full log](tests-initial-failed.log). It is not a pass.

1. `MacInteractionTests.searchShortcutClosesTheBarAndReopensEmptySearch`, for text `-` and Note mode, threw `NSCocoaErrorDomain` 4866. The validation-only Note-entry helper assumed every nonblank Search query offered New note. With #143, `-` correctly becomes an incomplete answer and hides capture suggestions; the helper's missing-suggestion guard deliberately throws `CocoaError(.coderInvalidValue)`. [Isolated run](isolated-failures.log) and [second reproduction](shortcut-reproduction.log) reproduced that exact case. Commit `e1f1e0c` expands the helper's existing temporary ordinary-text setup to whenever New note is unavailable, then restores the exact original text/selection and removes setup undo history. No original test assertion was removed or weakened. All nine shortcut parameter cases pass after this adaptation.
2. `MainNoteOrganizationTests.noteMenusActOnSelectionAndHaveKeyboardEquivalents` failed its signed native child's `dock-reopen` step. It passed in both isolated checks and the final full run. No cause or fix is claimed for that initial failure. Isolated successful child hashes were `902c59866b1480f623163915889698221a259a25ce9e472789d3051888f1b755` before the adaptation and `a1fdfc4e5ab92f24096db93cfe91e8a8df688a20e62d05b96344873e6315fe1a` afterward.

An agent-owned rerun on `e1f1e0c` ended without a test summary or captured exit status after its process handoff. [Incomplete log](tests-incomplete.log). It establishes no pass or completed count. The subsequent root-owned run supplied the final complete log and direct process result reported above.

## Limits and remaining milestone work

These fixtures establish the owned-origin responder and injected copy-action behavior. They do not establish a physical hotkey, foreign-app insertion-point preservation, or pasting into the user's invocation origin. #146 remains open for the human trial; #141 remains open for milestone completion.

#144 supplies full expression-language evaluation and undefined/too-large states using this shared row handling. #145 supplies the Calculation Automatic switch gate/debug reason. This evidence resolves only #143's bounded implementation.
