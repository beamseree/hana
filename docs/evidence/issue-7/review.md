# Two-axis code review

User-confirmed fixed point: `b6399e17bd60e6f27d6fd410dd36759900ecb341` (#6 merge). Command: `git diff b6399e17bd60e6f27d6fd410dd36759900ecb341...HEAD`. Independent parallel reviewers inspected implementation commit `b4c74ad` and correction commit `d6aec50`.

Standards sources: AGENTS.md, CLAUDE.md, docs/agents/{issue-tracker,domain,triage-labels}.md, GLOSSARY.md, docs/product-spec.md, relevant Search/native sections of docs/technical-design.md and docs/native-shell.md, ADRs 0002/0004/0005, plus the code-review skill's Fowler smell baseline. No CODING_STANDARDS.md or CONTRIBUTING.md exists.

## Standards

Initial: one P2 documented-standard violation. Spotlight disabled updates across the entire candidate universe and awaited filesystem/ranking work, conflicting with technical-design.md's requirement to snapshot bounded attributes and reenable promptly.

Follow-up: resolved in `d6aec50`. Spotlight disables updates only while synchronously copying at most 128 metadata values, then re-enables them before filesystem work or suspension. Revision checks reject superseded scans, and completed snapshots replace earlier results atomically. Additional changes preserve Search-owned ranking and usage, agreed test boundaries, and the separation of automated and native evidence.

**0 unresolved or new findings; 0 baseline smell findings.**

## Spec

Initial: two P2 implementation findings. Incremental replacement prefixes could temporarily discard a valid selected identity; usage-free adapter compaction could discard a recent successful-use winner before final ranking. Native demonstration remained pending at review time.

Follow-up: both resolved in `d6aec50`. Adapter compaction receives session usage before its cap. Replacement scans retain the previous complete result snapshot until the replacement is ready. The 300-file usage regression reproduces the failure and passes after the fix. The replacement regression is supporting coverage and passed before the fix too; it is not claimed as a reproduced scheduling failure. No scope creep identified.

**0 remaining implementation findings.** Native acceptance is recorded separately in validation.md and runtime.jsonl.

Standards: 0 remaining findings (initial worst P2). Spec: 0 remaining implementation findings (initial worst P2); native evidence tracked separately.
