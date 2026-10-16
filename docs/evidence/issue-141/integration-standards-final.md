# Final integration Standards review

Pinned source: `d54049ebef3f4674a27840fbfae0c12d3fed7e78` in `/Users/beamsereeyothin/.codex/worktrees/issue-141-calculator-numeric-fixes/hana`. Whole comparison: `d8fcf571c96b52b04b59c0cff6d5b98d9d2c1b12...d54049ebef3f4674a27840fbfae0c12d3fed7e78`.

The original whole-branch assessment through `38f4ab6` and numeric assessment at `924766b` remain applicable to unchanged code. This final recheck inspected `924766b...d54049e`; Calculation.swift and CalculationTests.swift are unchanged by that delta.

Standards applied: AGENTS.md, CLAUDE.md, tracker/triage/domain instructions, GLOSSARY.md, design system, accepted product specification, technical design, accepted ADR 0002, proposed ADR 0005, write-swift guidance compatible with Swift 6.3.3, and the complete code-review smell baseline. No CONTRIBUTING.md or CODING_STANDARDS.md exists.

## Documented-standard violations

None found. Calculation retains its pure synchronous text-plus-locale boundary, cohesive private numeric helpers, typed failures, checked scaling and public-seam parameterized tests. UI presentation uses design roles and keeps selection/dismissal outside arithmetic.

The harness follows the repository's existing owned NSApplication child pattern. `--validate-note-close` returns before normal Store/provider startup and creates only a newly marked disposable Collection. AppKit assertions run on the main actor; the semaphore pauses only the synchronous Store fault callback. NativeAppFixture owns a bounded signed child, checks process exit plus scenario and overall success markers, and terminates/cleans up its child on failure.

Original test names, parameter cases and native assertions remain represented, including the joint arrival-count/held-close/attached-sheet predicate restored at `d54049e`. The correction retains real native dispatch rather than weakening assertions or substituting simulated focus. Evidence continues to distinguish fixtures from physical acceptance, as required by docs/agents/domain.md and ADRs 0002/0005.

## Baseline smells — judgement calls

No actionable findings. One optional **Duplicated Code** note: `NoteCloseValidation.swift:132` repeats the pasteboard snapshot/restore shape in `NoteSaveSafetyNativeTests.swift:241`. Future reuse could consolidate validation support; this small duplication does not justify a product API or block the change. Other helpers remain cohesive and shared formatting/symbol presentation stay consolidated.

Read-only source review; no tests, native launches, providers, repository edits or GitHub mutations. Final full-suite and merged-source verification remain root-owned and are not claimed here.

**Standards: 0 hard violations, 0 actionable smells, 1 optional maintenance note. Worst issue: optional fixture pasteboard duplication.**
