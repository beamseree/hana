# #144 Standards review

Final head: `8dc7e18f99bcd428bd410a4157d1a76fa7181299`. Original fixed point: `cb3a7475d82c9d7ba0a00348f5bc32b67ee9ffde`. Reviewed the bounded diff against AGENTS.md, CLAUDE.md, tracker/triage/domain documents, GLOSSARY.md, accepted calculation specification, technical design, accepted ADR 0002, and write-swift. Rechecked corrections at `e5c2353`, `e0ca2f8`, `cdb6226`, and `8dc7e18`. Read-only source inspection; no repository mutations or test reruns.

## Hard documented-standard violations

None found. The evaluator remains pure and synchronous, uses value types, retains explicit locales, separates numeric failure from syntax failure, and uses Swift Testing. Documentation distinguishes fixture checks from physical acceptance.

## Initial judgement-call smells (resolved)

- **[P3] Duplicated Code — original `Sources/Hana/Calculation.swift:53–63` and `81–93`.** Both formatters repeated `formatter.numberStyle = scientific ? .scientific : .decimal`, `formatter.exponentSymbol = "e"`, grouping, and significant-digit policy. At `e5c2353`, both call one `formatted(_:scientific:fractional:locale:)` helper while retaining representation-specific rounding. Resolved.

- **[P3] Primitive Obsession — original `Sources/Hana/Calculation.swift:228–240`, related allowlist at 362.** `func applyingFunction(_ name: String)` ended with `default: result = Foundation.log(argument)`, splitting the closed function domain between strings and a separate allowlist. At `e5c2353`, the lexer creates a private raw-string `Function` enum and evaluation exhaustively handles its six cases. The silent fallback and duplicated allowlist are removed. Resolved; originally a maintenance recommendation informed by write-swift §8, not a blocking violation.

## Subsequent correction checks

The `e0ca2f8` exponent correction keeps logarithmic squaring with a Decimal magnitude, factors parity into private `isOdd`, documents the precision invariant, adds a parameterized regression, and updates the contract. No standards concerns.

The `cdb6226` parsing correction replaces the token cap with one private `nested` helper shared by recursive groups, functions, unary minus, and powers. `defer` restores its depth counter on success and failure; the explicit initializer preserves encapsulation. The 32-level limit, Too large result, and flat/nested regression agree with the updated technical design. No new standards concerns. Test execution and the earlier failed 128-level experiment remain implementer evidence, not independently rerun review evidence.

The final `8dc7e18` commit changes only CalculationTests: the flat sum remains separate and parameterized public-evaluator cases cover grouping, unary minus, powers, and functions at excessive depth. This follows Swift Testing guidance; source/docs remain as reviewed at `cdb6226`.

**Standards review passes at `8dc7e18`. No unresolved findings.**
