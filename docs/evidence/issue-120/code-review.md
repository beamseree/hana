# Two-axis integration review

Initial comparison: `git diff f39834c...6cea5a2`. Repair comparison: `git diff 6cea5a2...226d710`.

Original findings are retained below, followed by the original reviewers’ rechecks. The two P2 policy findings and the P3 fixture heuristic were repaired in one implementer branch. No actionable findings remain. Native and policy execution belongs to the integration evidence, not these read-only reviewers.

## Standards — initial review

Standards review: `git diff f39834cc8d75ae2f1c819c47eafc442c6098b2dd...6cea5a2`.

No documented-standard breaches found. The change retains AppKit ownership and main-actor native handling, constructs real variability at injected seams, keeps secrets and input text out of persistence/diagnostics, and distinguishes scripted/native evidence from the unfinished human trial (docs/agents/domain.md; docs/technical-design.md §§ Native windows, Collection model and persistence, Module interfaces and seams, Validation strategy; ADR 0002).

One heuristic finding:

- **[P3] Possible Duplicated Code — consolidate Word-paced native fixture setup.** `Tests/HanaTests/JevWordPacedNativeTests.swift:262`, `JevWordPacedDeletionNativeTests.swift:154`, and `JevWordPacedWithdrawalNativeTests.swift:191` each repeat the isolated defaults, Word-paced settings, log lifecycle, and `MacInteraction(search: Search(source: { AsyncStream ... }), collection: Task { store }, ...)` construction. The copies have already diverged: deletion/withdrawal publish an empty `.ready` batch, while the tracer fixture only calls `$0.finish()`, leaving Search loading. The #124 evidence documents that exact missing-terminal-batch fixture error. Extract shared native fixture construction with explicit options/memory overrides and one correctly completed empty Search source, so future integration changes reach all three suites. This is a maintainability judgment from the Duplicated Code baseline, not a hard repository-rule violation.

No source edits or tests were run by this reviewer. Native execution and final integration evidence remain with the integration owner.

Findings: 0 documented violations; 1 low-priority heuristic.

## Spec — initial review

1. **[P2] Agreement can come from text that was replaced.** #123 requires a borderline answer to switch only when “the previous handled answer, for the same text or the words before it, had the same label at or above the threshold.” `Sources/Hana/AutomaticSwitch.swift:361-369` tracks only label/count; non-append edits preserve that history (`410-470`). After a Task 0.80 verdict for `call mom`, replacing the entire buffer with unrelated `buy milk`, waiting out the burst, and receiving Task 0.80 switches using the unrelated first verdict. Retain/check the previous answer’s normalized prefix, and break agreement when it no longer applies. Add coverage for unrelated replacement and deletion before the previous answer’s words.

2. **[P2] Cancelled-but-running requests escape deduplication.** #120 requires that text “isn’t identical to a request in flight”; #122 likewise requires “no identical request is in flight,” while counting leftovers “until they finish.” `Sources/Hana/AutomaticSwitch.swift:482-483` checks only valid requests in the current policy. Cancellation marks requests invalid while retaining their launch slot (`518-522`), and `Sources/Hana/JevLaunchMemory.swift:18,84-86` remembers only their IDs. Deletion followed by retyping before cancellation finishes, or quickly reopening the bar while one previous request remains, can send the same normalized text again through the unused second slot. Keep normalized request identities through terminal completion and include leftovers in dedupe; test both scenarios with a held, cancellation-delaying classifier.

No actionable scope creep found. #127’s dedicated session and conditional omission of preconnect match the ticket; its research states the evidence limit honestly. #128’s few-days trial remains explicitly pending, with Beam’s pipeline observation separated from automated claims. It must remain open, but that elapsed human trial is not a code defect.

## Standards — repair recheck

Standards recheck of `git diff 6cea5a2...226d710225ab21dbe9c55b97a5ffca2309229202`, retaining original review base `f39834cc8d75ae2f1c819c47eafc442c6098b2dd`.

**The P3 Duplicated Code finding is resolved.** All three Word-paced native suites now use `JevWordPacedNativeFixture`. Its single Search source publishes empty `.ready` before finishing. The initializer exposes an explicit options override, and interaction construction accepts launch-memory injection; withdrawal tests preserve their `.saves` setting. The three copied fixture implementations are removed.

**No new documented-standard breaches or material baseline smells found.** The added agreement-prefix check stays inside `AutomaticSwitch` policy behavior and its regressions use the established `handle(event) → effects` seam with a fake clock. Launch request tracking stores typed SHA-256 digests alongside request UUIDs rather than raw pending text; transient hashing adds no persistence or diagnostics path. Completion remains idempotent and governs identity lifetime. The new helper is test-only, main-actor isolated, and represents existing repeated fixture behavior rather than speculative production abstraction.

Applicable standards: docs/agents/domain.md (evidence distinctions); docs/technical-design.md §§ Collection model and persistence, Module interfaces and seams, Validation strategy; ADR 0002; TDD skill's behavior-through-interface rule. The change preserves their relevant boundaries.

Read-only inspection only. I did not run tests, native checks, installation, or source edits; reported test results remain the integration owner's evidence.

Recheck findings: 0 open documented violations; 0 open heuristic findings.

## Spec — repair recheck

Rechecked `6cea5a2...226d710225ab21dbe9c55b97a5ffca2309229202` against #120/#122–#128. Both original P2 findings are resolved in the repair delta; no new actionable spec regression found.

- **Agreement provenance:** #123 requires the previous answer to concern “the same text or the words before it.” `Sources/Hana/AutomaticSwitch.swift:367-373` now requires the new answer’s normalized prefix to start with the previous agreement prefix, and `439-441` clears agreement when an edit removes that prefix. `AutomaticSwitchReviewPolicyTests.replacingThePreviousAnswersWordsBreaksBorderlineAgreement` covers unrelated replacement and deletion before the prior answer’s words, followed by a genuinely agreeing later answer.
- **In-flight deduplication:** #122 requires “no identical request is in flight” and retains leftovers “until they finish.” `Sources/Hana/JevLaunchMemory.swift:19,85-92` now retains a transient SHA256 fingerprint with each launch-wide request ID until terminal completion. `AutomaticSwitch.swift:492-506` checks that identity before admission, retaining the newest text as waiting rather than sending it twice. The new policy tests hold terminal callbacks through deletion/retyping and close/reopen, including whitespace/NFC equivalence, and verify release resumes the deferred request.

The cache still applies before the new in-flight check, backoff still gates actual sends, and the shared cap remains two. The native fixture consolidation preserves each suite’s relevant settings; its terminal Search batch makes held Enter settle as required without changing production behavior.

This was a read-only source/test review; I did not run tests, native interactions, installation, or live API calls. Reported red/green and native pass counts remain the implementer’s execution evidence; the root’s integrated serial run is still required. #128 remains pending human evidence, not a code defect.

Final review status: Standards — 0 documented violations, P3 heuristic resolved. Spec — both P2 findings resolved, 0 remaining actionable findings. #128’s human trial remains pending.
