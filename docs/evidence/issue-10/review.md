# Two-axis review — issue #10

User-selected fixed point: `20e67f87355d6c8d6c3d72adc8129b692e5be29d` (merged #9, #4/#7/#8 and PR #17). Initial reviewed head `c186fde`; command `git diff 20e67f87355d6c8d6c3d72adc8129b692e5be29d...HEAD`. Independent Standards and Spec subagents reviewed read-only without using the native slot or running builds/tests. Final evidence changes will receive a follow-up review.

## Standards

No actionable findings. No documented-standard violations or sufficiently concrete heuristic smells found. Spotlight ownership/value snapshots are preserved, validation is opt-in, and automated timings are distinguished from physical observations. ADR 0005 remains proposed.

## Spec

No substantiated implementation defects or scope creep. The metadata change preserves query ownership/ranking; the punctuation assertion correction retains specific literal-file checks. Three acceptance gaps were recorded separately: final integrated suite/signature recheck, remaining physical native/destination evidence, and the narrower scope of measured timing proxies. Root is completing the first two; physical shortcut-to-typing p95 remains unmeasured. The later `hana9` coverage failure and same-binary permission probes must also be reflected in the final assessment, not replaced by #9's prior pass.

Totals at initial review: Standards 0 findings; Spec 0 implementation findings, 3 acceptance gaps. No cross-axis reranking. PR remains draft and parent #2 open.

## Standards — final follow-up

No actionable documented-standard violations, heuristic smells, or evidence inconsistencies found. Debug timing failures, bounded release results, permission/display changes and physical observations are distinguished. Read-only review against the same fixed point, including final working-tree evidence.

## Spec — final follow-up

No substantiated new implementation defect or scope creep found. Final deterministic build/signature, lifecycle, editing, display and styling gaps are closed. Two limitations remain: exact Two app selection through late-file arrival is only tentatively confirmed (“works i think”), and responsiveness evidence is qualified by debug timing failures, one release first-file sample over the preferred 300 ms threshold, and unmeasured physical latency/stall targets. Keep the PR draft and #2 open. Permission changes and successful acknowledgments are not promoted to sole-cause or focus proof. The original unexplained minimize observation remains preserved.

Final review totals: Standards 0 findings; Spec 0 substantiated implementation findings, 2 acceptance limitations. Both reviewers ran read-only; neither used the native slot or ran tests/builds.

Post-review timing isolation: optimized test-process timing also failed at 89.78 ms; idle and local-only controls passed. Reducing copy chunks failed and was reverted. This strengthens the same unresolved responsiveness limitation; no additional production change was retained.

The Spec reviewer reread the final timing-isolation paragraph: no overclaim or missing requirement; the controls and remaining unknown cause satisfy the requirement to investigate misses without claiming unmeasured guarantees. No production changes followed the two-axis review. Final documented sequential suite passed; a later rebuild’s binary hash differs from the preserved installed human-tested artifact despite identical source, and both identities are now explicitly recorded rather than conflated.
