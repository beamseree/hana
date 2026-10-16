# Standards repair review

Scope: candidate `4eec8ef` to source/test repair `b1e9cfd`. This is the repair agent's source assessment, not an independent second review.

1. **P2 title preparation: repaired.** The explicit concurrent function prepares the entire immutable title snapshot, including SearchName tokenization. The observing task awaits preparations serially, with cancellation before publication. MainActor owns publication only. Real temporary Collection Store snapshot tests pass. The existing gate scan remains linear; no measured slowdown or profiling result is claimed.
2. **P3 common transition: repaired.** Both return routes now invoke the same reset/cancel/end helper. Caller-specific diagnostics remain distinct; the helper records at most one end and resets hysteresis consistently. Existing reversal and late-match policy tests pass.

No additional actionable source-standard issue found in this repair's diff. The unlocked focused native regression passed, followed by 374 tests in 49 suites on pinned source `b1e9cfd`; final build and range checks passed. Real provider/trial acceptance is separate from code-standard status.
