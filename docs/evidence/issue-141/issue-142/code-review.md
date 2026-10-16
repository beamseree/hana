# #142 code review

Fixed comparison: `git diff d8fcf571c96b52b04b59c0cff6d5b98d9d2c1b12...HEAD`.
Initial implementation: b5c996e. Review fixes: aa012fc.
Two independent read-only reviewers used the code-review skill's Standards and Spec axes; neither ran native tests.

## Standards

Initial report: one documented P2 violation. The new calculator icon used `.font(.system(size: 18))`, contrary to `docs/design-system.md`'s requirement to use named font roles. A separate Duplicated Code judgement call identified repeated symbol styling shared with suggestions.

Resolved: `HanaFont.Row.symbol` defines the existing 18-point appearance and is documented in the design-system table. `SearchResultsView.symbol(_:)` shares it across answer, suggestion and fallback icons. The reviewer confirmed both fixes and reported no remaining Standards concerns.

## Spec

Initial report: one P2 finding. `999999999999999.9 + 0` rounded into a 16-digit whole number after ordinary notation had already been selected, violating the scientific rule beyond 15 integer digits.

Resolved: fractional values round with `NSDecimalRound`, using the Decimal exponent and significand digit count, before notation is selected. The new public evaluator regression expects display and copy text `1e15`. The reviewer confirmed the fix, including positive/negative and comma-decimal probes, and reported no unresolved scoped Spec findings.

A self-review found that `x` recognition between leading-decimal numbers (`.3 x .4`) incorrectly required adjacent digit characters. A failing evaluator recognition case reproduced it; recognition now checks the preceding numeric token and the next number's start. Targeted checks pass.

Final totals: Standards 1 documented finding and 1 maintainability suggestion, resolved; Spec 1 finding, resolved. No unresolved findings in either axis. Non-value states (#143), the full language (#144), Calculation gate (#145) and human trial (#146) remain separate work.
