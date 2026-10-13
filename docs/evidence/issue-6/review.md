# Two-axis review — issue #6

User-confirmed fixed point: `d57ea7e6ade47202ce406653420061f5c0d4575d` (#5 / PR #13).
Diff: `git diff d57ea7e6ade47202ce406653420061f5c0d4575d...HEAD`.
Initial implementation: `f806ad5`. Independent read-only Standards and Spec agents reviewed in parallel. Neither ran native tests during interactive validation.

## Standards

Initial finding: **P2 — deduplication discards matching metadata aliases.** Search inserted a destination into `seen` before evaluating its names. This contradicted the technical design's filename matching and match-quality ordering: a catalog `TextEdit` could hide a metadata `TextEdit.app` match. No additional actionable baseline smells or lifecycle/concurrency breaches were reported.

Correction: merge searchable names by exact destination before scoring, preserving catalog presentation. A failing Search-boundary `Notes.app` regression passed after correction; a second check covers stronger metadata matching without changing the catalog display name.

## Spec

Initial finding: **P2 — valid filename matches supplied by Spotlight were dropped**, against “supplement app discovery with application metadata” and “Deduplicate the same app across catalog and metadata.” Same code correction as above. No additional actionable code defect or scope creep was reported.

Separate acceptance gap: physical keyboard/focus/full-screen checks were still pending during review; the runtime acknowledgment alone did not close that gap.

Initial totals: Standards 1 (worst P2); Spec 1 (worst P2).

## Final Standards recheck

The independent reviewer rechecked `eff9b53`: no remaining actionable findings; the P2 was resolved. No additional documented-standard violation or actionable baseline smell was found.

## Final Spec recheck

The independent reviewer rechecked `eff9b53`: no remaining actionable findings; the new tests cover metadata-only filename matching and stronger metadata tiers. Physical acceptance was still pending when reviewed.

Final totals: Standards 0 remaining; Spec 0 remaining. Both original P2 findings resolved.


## Physical acceptance follow-up — 2026-10-13

Beam subsequently answered “All checks pass” to the final signed-build focus, keyboard, full-screen and working-window procedure. The prior acceptance gap is closed by that human observation, recorded separately from native acknowledgments in [validation](validation.md#physical-acceptance). No source changes followed the reviewed build; the two-axis totals remain Standards 0 and Spec 0.
