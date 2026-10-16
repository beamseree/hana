# Standards review — final numeric fixes

Pinned comparison: `git diff 38f4ab6406aa342bd3691469f4a9aef3be8ce0ea...9f82dc3146ec320dd5d2a1512d653bd3aeb2c90a`.

Commits reviewed: `a0ce847`, `74ca1d8`, `9f82dc3`.

**Hard violations: 0. Judgment-call smell findings: 0.**

The changes preserve the pure synchronous Calculation boundary required by `docs/technical-design.md` (“Calculation answers” and “Module interfaces and seams”). Numeric representation, scaling, failure mapping and locale-independent canonical literal parsing stay inside the evaluator. No AppKit, Search-source, Automatic switch or persistence dependency is added.

The new tests use a value-type suite, Swift Testing, `#require` and parameterized arguments as required by `write-swift/SKILL.md` §11 and the repository validation strategy. They assert public answers, display/copy agreement, numeric failures, signed values and locale behavior rather than private helper structure. The new radix force unwrap states its exactly representable constant invariant, consistent with the skill’s §2 guidance. The fixed-width coefficient reconstruction uses checked arithmetic and public Foundation constructors.

Reviewed AGENTS/CLAUDE instructions, domain/tracker/triage documents, glossary, design system, product specification, technical design, ADRs 0002/0005 and the Swift skill. No additional CONTRIBUTING/CODING_STANDARDS file was present. The Fowler baseline yielded no actionable new smells; short repeated sign extraction and explicit Decimal boundary values do not warrant extra abstractions in these tightly scoped numerical helpers.

This is a read-only source review. No tests or native fixtures were run. Raw logs are retained output, and earlier reports pinned to `a0ce847` are historical evidence, not proof for the final head; the final-suite report remains the implementer’s pending evidence update.
