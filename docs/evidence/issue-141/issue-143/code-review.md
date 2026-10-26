# #143 code review

Fixed comparison: `git diff aaef64fd27f78b83d0c974662f425ceed0a4e678...HEAD`.
Initial implementation: `0371fb05a9ed13b92747e30a35bc59a3d5b1e17c`.
Review cleanup: `79aa5659934fa0ed862ec5466db1d97bb1963b0f`.
Fixture adaptation: `e1f1e0c64792bc2c30ba0038d6b2c76c271beb04`.
Two independent read-only reviewers used the code-review skill's Standards and Spec axes. Neither ran native tests.

## Standards

No documented-standard violations were found. The evaluator remains synchronous and independent of Search/UI state; Mac Interaction owns row selection. Tests use Swift Testing at the agreed text-plus-locale and real Mac Interaction boundaries with fixture sources and a recording copy action. Evidence distinguishes fixture checks from physical focus acceptance.

One optional P3 Duplicated Code judgement call identified the standalone `12 *` and `5 / 0` tests repeating the parameterized state table's assertions. The standalone tests were removed in `79aa565`, preserving all 18 table cases and their state/title/subtitle/copyable-text assertions. The Standards reviewer verified the deletion and confirmed no outstanding findings.

## Spec

No actionable findings. The reviewer found that exact wording, incomplete/invalid boundaries, division by zero, row order, suggestion suppression, first-result selection and opening, only-row dismissal without copying, the `12 *` to `12 * 4` transition with and without navigation, late-batch selection and technical documentation match #143.

Preserving user choice through consecutive calculation edits implements the ticket's “unless the user moved the selection.” Full expression-language evaluation and undefined/too-large states remain with #144; Automatic switch gate/debug behavior remains with #145. This source review does not establish a full-suite pass or physical foreign-app focus behavior.

Final totals: Standards 0 hard violations and 1 optional suggestion, resolved; Spec 0 findings. No outstanding findings in either axis.

## Full-suite fixture follow-up

The initial full suite exposed an existing Note-entry fixture assumption: nonblank `-` was expected to offer New note, but #143 correctly turns it into an incomplete answer and suppresses suggestions. The helper's missing-suggestion guard threw `CocoaError(.coderInvalidValue)` (4866). An isolated rerun reproduced that exact argument twice. In `e1f1e0c`, the helper's existing temporary ordinary-text setup now applies whenever New note is unavailable, restoring the original text, selection and setup undo state afterward. All original shortcut assertions remain intact. Both reviewers checked this bounded adaptation and reported no findings.

The other initial full-suite failure was the native child fixture's `dock-reopen` step. It passed in two isolated runs without a product or fixture change addressing that step; no cause or fix is claimed for it.
