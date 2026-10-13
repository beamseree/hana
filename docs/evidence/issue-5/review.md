# Two-axis code review

Fixed point: `c7abb2e8dfe12eb469b66db29b3dd89a136aa8c0` (verified current main at task start).
Initial implementation commit: `6c401eb`.
Command: `git diff c7abb2e8dfe12eb469b66db29b3dd89a136aa8c0...HEAD`.
Two independent read-only reviewers used repository standards and issue #5 / parent #2.

## Standards

No actionable findings. The changes preserve the documented AppKit/SwiftUI split, retained native editor, main-actor platform boundary, typed installation identity, content-free diagnostics, and separation of automated evidence from physical observations. No baseline smell warrants a change.

## Spec

1. P1: An older launch can still dismiss a newer invocation through workspace notifications. The completion is guarded, but resetting the session discards the pending destination. A delayed native activation or Space change can therefore dismiss the reopened bar. Required: retain outstanding native-operation identity independently of the visible invocation and cover the notification sequence.
2. Acceptance evidence partial at review time: final English/Thai editing, observed distinct installations, running-app recovery, and timings remain to be recorded. This is an evidence gap, not an implementation bug.

Initial totals: Standards 0; Spec 1 correctness finding (P1) and 1 evidence gap. Follow-up disposition is recorded after correction and physical validation.


## Follow-up disposition — aed41f9

**Standards:** No actionable findings in the correction. The exact-instance activation effect remains within Mac Interaction, on the main actor, after invocation/query guards without suspension. Environment dismissal is preserved.

**Spec:** No remaining actionable code findings. Native opening requests no activation; only a current acknowledgment can dismiss and activate the exact returned instance. Tests cover stale/new-query completion and ordinary Space dismissal. Recorded evidence covers distinct installations, failure recovery, English/Thai input and initial timings. The final revised activation path still requires the requested physical recheck; earlier physical results predate that correction.

Final code-review totals: Standards 0; Spec 0 code findings. Final physical recheck is tracked in validation.md.
