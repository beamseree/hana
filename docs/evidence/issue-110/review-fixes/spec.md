# Spec repair review

Scope: candidate `4eec8ef` to source/test repair `b1e9cfd`. This is the repair agent's source assessment, not an independent second review.

1. **P1 saving Escape: repaired.** A reversal requires eligible editing state and no composition. Escape refreshes current adapter eligibility before calling the policy. Saving/saved capture reaches ordinary dismissal rather than being swallowed as a false reversal. Pure-policy red/green verifies preserving the saved end and no reversal effect. The initial locked-console attempts failed at editor setup and are retained separately. After Beam unlocked and handed the slot back, the native regression reproduced a remaining saved-confirmation ambiguity count, then passed after end status was corrected to saved whenever the capture already committed. Both native cases now verify exactly one saved note, no wrong/reversal/ambiguous counts, and one saved end. The exact-source full serial suite passed: 374 tests in 49 suites on `b1e9cfd`.
2. **P2 latency duplication: repaired.** A timed-out request's late cancellation acknowledgement or verdict remains a stale diagnostic without another latency sample. A second normal request is sampled. Persisted diagnostics red/green verifies exactly two samples, median 800 ms and maximum 1500 ms for the worked case, with one timeout and zero errors.

No additional actionable source/spec issue found in this repair's diff. #114 real classifier checks, #115 days-of-use trial, #105 and #110 acceptance remain pending. Installation/trial launch are held.
