# #144 validation — full calculation language

Date: 2026-10-16. Tested source: `8dc7e18f99bcd428bd410a4157d1a76fa7181299`; evaluator/docs source is unchanged from `cdb6226`. Integration tip `cb3a7475d82c9d7ba0a00348f5bc32b67ee9ffde` is merged. The final evidence commit changes documentation only.

## Automated checks

- Full serial suite: `xcrun swift test --no-parallel` passed **641 tests in 93 suites**, 107.897 seconds (111.883 seconds process wall time), **exit 0**. The **11 existing live-index checks were skipped by environment gates**. Complete output and direct process result: `26-full-tests.log` and `26-full-test-result.json`.

- Final evaluator: `xcrun swift test --no-parallel --filter CalculationTests` passed **12 tests in 1 suite**, 0.017 seconds, exit 0 (`24-recursive-shapes-tests.log`). Parameterized cases include every symbol/function/constant, exact Decimal powers and relative percentages, precedence, scientific literals and `e`, comma-decimal typing/copying, all explanatory states and syntax priority. A valid 300-term pasted sum returns `300`; all four 1024-level recursive shapes return Too large without copying.
- Combined Calculation/Automatic switch/Strong Match Gate checks passed **25 tests in 5 suites**, 7.374 seconds, exit 0 (`19-final-calculation-tests.log`, before the separate nesting regressions). This includes the actual undefined/too-large evaluator states with the merged gate work.
- Native Calculation Interaction fixtures passed **8 tests in 1 suite**, 1.753 seconds, exit 0 (`13-calculation-interaction.log`). A function answer copies through real editor Enter while fixture sources load; undefined/too-large only-row Enter dismisses without copying and restores the owned fixture origin responder. Existing result selection, late batches, capture exclusion, paste and ordinary editor copy remain covered.
- `xcrun swift build` passed after merging the integration branch (`14-build-after-integration.log`). Every subsequent evaluator/native test run also compiled and typechecked its changed source. `git diff --check` passed.

## Red/green and review evidence

The numbered logs retain failing runs and their corresponding green iterations for powers, percent, functions, implicit multiplication/scientific literals, numerical states and huge-exponent parity. `09-numeric-states-red.log` ended with signal 5 as the former Foundation power path reached the minimum-integer exponent case. The bounded squaring implementation and the final full suite cover that regression.

The independent Standards review raised two P3 maintainability findings (duplicated formatting policy and string function dispatch); a shared formatter helper and exhaustive Function enum resolved both. Spec review raised two P2s: a representable answer with an exponent beyond signed Int was incorrectly rejected, and the inherited 512-token cap rejected a valid long pasted sum. Exact Decimal exponent squaring and a separate recursive budget resolved both. Both axes cleared final head `8dc7e18`; reports are committed beside this file.

The independently worked large-exponent answer `1.000000000000000001^9223372036854775808 = 10,131.169` has failing/passing logs 17/18. The valid flat sum has failing log 20 and passing logs 23/24. The first nesting edit had a private-initializer compilation error (21), then an initial 128-level limit crashed with signal 10 (22); both are preserved as failed evidence. The final documented 32-level resource limit passes grouping, unary-minus, power and function recursion through the public evaluator seam. Finite Double result `10^200.5 = 3.1622777e200` remains representable without conversion through Decimal.

## Limits

These are automated pure/evaluator and owned AppKit fixture observations. No install, real provider request, permission/settings change, physical foreign-app focus return, or paste into a foreign application was performed. The separate human trial #146 remains open; #141 is not closed by this evidence. The native testing slot is released after completed verification.
