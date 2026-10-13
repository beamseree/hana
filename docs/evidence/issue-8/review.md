# Two-axis review — issue #8

Fixed point, confirmed by Beam: `b6399e17bd60e6f27d6fd410dd36759900ecb341` (main including #6). Command: `git diff b6399e17bd60e6f27d6fd410dd36759900ecb341...HEAD`. Independent parallel Standards and Spec agents reviewed `6c6078d`, then rechecked the changes committed as `bde8da0`. Both reviewed the final evidence delta and human-assisted reproduction script after the authorized native slot.

## Standards

No remaining actionable Standards findings. The changes preserve AppKit ownership and retained editor identity, keep geometry within Mac Interaction, isolate optional Accessibility reads, and distinguish automated evidence from native observations. No baseline smell warrants a change. The final global-event change follows the documented outside-click rule, and the continuation fixture models cancellation-insensitive IPC accurately.

The evidence review corrected the suite count: **34 tests total, 33 passed and one opt-in indexed-fixture test skipped**. The isolated Search run was 16 total, 15 passed and one skipped. No other documentation/script issue was found. `bash -n scripts/validation/foreign-input-loop` passed.

## Spec

No remaining blocking Spec findings for #8. The final evidence covers editing, menus, outside-click focus, resizing, three-display placement, owned-window precedence and reinvocation. Tested revision/build identity, suite result, shutdown, shortcut release and #7's merge check are recorded.

Initial review correctly kept the PR draft while native acceptance was incomplete. It identified outside clicks during menu tracking as an essential test target. Foreign-app mouse events now dismiss regardless of delayed menu-end notifications; local native-menu protection remains. The reviewer accepted the correction, and Beam's physical menu/outside-click procedure passed.

Retain the initial foreign-typing failure prominently as an **unresolved, nonreproducing observation**. Six reported physical cycles using the previously failing app, across both activation policies, provide scoped acceptance evidence; they do not establish a cause or fix. Grouped human confirmation is distinguished from narrower runtime corroboration rather than inventing a trace-derived count.

Trusted AX success and real denial/revocation remain explicitly untested; runtime used pointer fallback and did not log the actual trust/lookup failure reason. Candidate IME and broad platform hardening remain deferred. No new source-code defect or scope creep was identified. Scoped readiness is supported without claiming broad native-platform reliability.

Standards: 0 remaining findings. Spec: 0 blocking findings, with 1 documented residual focus risk (initial failure, not reproduced in final physical acceptance).
