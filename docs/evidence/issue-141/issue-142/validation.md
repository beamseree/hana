# #142 — basic arithmetic answers in Search

Validated on 2026-10-16 against implementation aa012fc, based on integration d8fcf571c96b52b04b59c0cff6d5b98d9d2c1b12. Host: macOS 26.4.1 (25E253), arm64, Apple Swift 6.3.3. Native testing slot was explicitly granted for disposable fixture tests. No app installation, real classifier/provider request, permission change or system setting change was performed.

## Automated evidence

- `xcrun swift build` passed; the final targeted/full test commands also compiled the final Swift sources.
- `xcrun swift test --no-parallel --filter Calculation` passed **10 tests in 2 suites** after both review fixes. Tables cover 26 recognition cases, 14 basic arithmetic cases and 11 formatting/copy cases, plus the locale and native interaction scenarios. Raw [calculator log](calculator-tests.log).
- `xcrun swift test --no-parallel` passed **623 tests in 91 suites**, 106.985 seconds, exit 0. **11 existing live-index tests were environment-gated skips**; no live-index coverage is claimed. Raw [full log](tests.log).
- Red/green implementation used the agreed text+locale evaluator boundary and real Mac Interaction fixture boundary. [Red excerpts](red-evidence.log) preserve the missing evaluator/interface failures, arithmetic/formatting behavior failures, decimal-x regression and rounding-carry regression. Raw development logs remain outside the repository at `/tmp/hana-issue-141-context/issue-142-evidence`.
- Independent [two-axis review](code-review.md) finished with no unresolved Standards or scoped Spec findings.

## Acceptance mapping

| Requirement | Evidence |
| --- | --- |
| Recognize calculations while preserving ordinary text/number searches | `recognizesOnlyTheCalculationLanguage`: bare `2024`, `pi`, `e`, unknown words, date-shaped calculations, incomplete/invalid calculations, every recognized vocabulary family and numeric `x` contexts. Recognition is independent of whether a value exists. |
| Exact basic arithmetic, unary minus, precedence, parentheses | `evaluatesArithmeticWithExactDecimals`: `0.1 + 0.2 -> 0.3`, `2 + 3 * 4 -> 14`, `(2 + 3) * 4 -> 20`, `-5 + 3 -> -2`; incomplete, invalid and division-by-zero inputs return no row in this slice. |
| Locale, 15-digit whole numbers, 8 significant digits and scientific notation | `formatsAnswersAndCopyableText` and `typingAndDisplayFollowTheExplicitLocale`: integer/scientific thresholds, fractional rounding, trailing zeros, exact copy text, German decimal/grouping separators, and rounding carry to `1e15`. |
| First/default answer, same edit update, late batches and explicit result selection | `answerStaysAboveLateBatchesAndPreservesAnExplicitResultSelection`: synchronous first/default answer, app/file batch arrival, preserved answer selection, preserved explicit app selection, normal opening action. |
| Suggestions, Search mode/icon, pasted negative text, capture exclusion | `suggestionsReturnAsSoonAsTheTextGainsAWord`, `calculationsStayPlainTextInCapture`, `pastedNegativeCalculationWorksAndEditorCopyRemainsOrdinary`. Real paste and editor copy temporarily use and restore the existing pasteboard. |
| Enter copies immediately during loading and restores invocation origin | `enterCopiesTheDefaultAnswerImmediatelyWhileSourcesLoadAndReturnsToTheOrigin`: recording copy action gets exactly `400`, closes synchronously while sources load, restores an owned fixture panel's key status and original responder. No confirmation. |
| Product and technical decisions | Product spec calculator section, Mixed search evaluator/row section, Calculation/Answer glossary entries; deferred scope is explicit. |

## Limits and remaining work

The native fixture establishes the owned-origin responder path and injected clipboard action. It does not establish physical hotkey latency, foreign-app insertion-point preservation or a real paste into the user's invocation origin. #146 remains open for that human trial.

This bounded ticket deliberately returns no Answer for recognized text that cannot be evaluated by the basic parser. #143 adds the explanatory states and their selection rules; #144 adds the full language (including the trial's standalone scientific-number clarification); #145 blocks Automatic switch for every recognized calculation state. Neither #141 nor #146 is closed by this evidence.
