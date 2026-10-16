# #141 numeric review fixes — validation

Date: 2026-10-16. Tested and reviewed source: `a0ce847979ddee6f3a1c72943d4602b613e27d60`, based on integration `38f4ab6406aa342bd3691469f4a9aef3be8ce0ea`. Latest integration was fetched and merged before the final run (already up to date). Host: macOS 26.4.1 (25E253), Apple Swift 6.3.3, Xcode 26.6 / SDK 26.5. The subsequent evidence commit changes documentation only.

## Change and independent references

The two whole-integration Spec findings for #141/#142/#144 were reproduced through the agreed public `Calculation.answer(for:locale:)` seam. Foundation multiplication returned `.noError` with a wrapped exponent (`1e-65 * 1e-64` copied `1e127`); Foundation division reported underflow for the representable `1e-100 / 1`, `/ 10`, and `1e-128 / 1`. Direct Foundation probes are preserved in `foundation-probe.swift` / `.log`.

Products and quotients now operate on signed Decimal significands, carry decimal scales separately, and validate the combined exponent before applying it. Near the lower bound the result retains Decimal's representable precision; nonzero magnitudes below `1e-128` remain Too large. All exact operations stay in Decimal; existing upper-range errors and approximate Double behavior are preserved.

Independent Python Decimal at 200-digit precision confirms `1e-65 * 1e-64 = 1e-129` (Too large), `5e-65 * 2e-64 = 1e-128`, `2^-400 = 0.5^400 ≈ 3.872591914849318...e-121`, and the small quotients. `numeric-reference.py` / `.log` retain those references.

## Automated checks

- Final `xcrun swift test --no-parallel`: **644 tests in 93 suites passed**, **119.450 seconds** test time, **123.486 seconds** process wall time, **exit 0**. **11 existing live-index checks skipped** by their environment gates. Complete output: `08-full-tests.log`; direct process result and source identity: `08-full-test-result.json`.
- `xcrun swift test --no-parallel --filter CalculationTests`: **15 tests in 1 suite passed**, 0.022 seconds, exit 0 (`05-boundaries-and-locale-evaluator.log`). New tables add 42 independent cases across all product/division signs, the lower representable boundary, genuine overflow/underflow, precision at the lower bound, fractional arithmetic, zero, percentages and integer powers. The explicit comma-decimal locale also exercises a small quotient. Existing tests retain recognition, display/clipboard rules, syntax precedence and large finite Double results.
- `xcrun swift build`: passed, exit 0 (`07-build.log`). Targeted test runs also compile/typecheck the changed source. `git diff --check` passed.
- Red/green: `01-multiplication-red.log` exits 1 with the original copyable `1e127`; `02-multiplication-green.log` passes after the first slice. `03-division-red.log` exits 1 for all three representable quotients; `04-division-green-evaluator.log` passes after the second slice. The first single red test was later consolidated into the permanent parameterized range table. Complete failed outputs are retained.

## Two-axis review

The pinned diff `38f4ab6...a0ce847` received independent parallel reviews: **Standards: 0 hard violations / 0 actionable smells; Spec: 0 findings**. Reports are `standards-review.md` and `spec-review.md`. The Spec reviewer independently checked the original reproductions plus **420 product/division grid cases with zero mismatches** (`numeric-review-grid-result.json`) and **8 locale/error/mixed Double regression checks**. The final full suite ran after both reviews cleared; no review fixes were needed.

## Limits and handoff

These are automated evaluator and disposable AppKit fixture checks. No app installation, real provider request, privacy/settings change, physical foreign-app focus observation, or paste into a foreign application occurred. The native testing slot was released after the full process exited. Parent #141 and the separate human trial #146 remain open; this fix PR does not close either. The root orchestrator owns merging the draft fix PR into the integration branch.
