# Two-axis review — issue #29

Baseline: `210e9f34de86d751de6eb80a584cc41cde560ee3`
Reviewed implementation commit: `b08b41e`
Diff: `git diff 210e9f34de86d751de6eb80a584cc41cde560ee3...HEAD`

## Standards

No hard standards violations. Initial nonblocking suggestions: replace force unwraps with `#require`; model inspection success/failure as a mutually exclusive result; consider a scoped Store helper. Test assertions and `Result<SnapshotManifest, SnapshotError>` were applied. Follow-up review verified both changes; keeping explicit cleanup for different Store acquisition paths was accepted. No outstanding findings.

## Spec

No Spec defects or scope creep. Manual creation/list/inspection/status, writer-barrier online backup, WAL/concurrent-command behavior, staged closure/validation, manifest publication, disposable reopening, full organized-state equality, damaged-candidate rejection, explicit retry and preservation of earlier copies are implemented. The single source writer is retained. Combined AC10 remains coordinated pending evidence, not an implementation defect or a claimed pass.

Final review count: Standards 0 outstanding (3 initial nonblocking suggestions resolved/dispositioned); Spec 0 defects (combined AC10 evidence pending).

## UUID correction review — 2026-10-14

A later independent review reproduced a P2 missed by the initial review: lowercase stored note/task UUIDs could be accepted by snapshot validation but fail Store ID lookups after reopening. This supersedes the initial zero-defect assessment for the pre-fix source.

Fixed point: `c1bd4ff4a7aecc0de19e205a8046bcfe525bd86b`. Reviewed fix: `57a756aad05549eb5207a34b00c3b75d1d5fd8d0`.

### Standards

No findings. Canonical ID validation follows the existing case-sensitive Store binding contract. The negative regressions isolate representation by maintaining foreign keys and hashes; the positive regression checks ID reads/mutations and original-copy preservation. No ownership drift or speculative abstractions.

### Spec

The P2 is resolved. Noncanonical note/task IDs are rejected before reporting compatibility or creating a disposable Store. Both red cases, their green rechecks, and canonical read/mutation coverage establish the intended behavior. No scope expansion or remaining findings. Refreshed combined validation passes separately as recorded in the evidence.

Fix review totals: Standards 0; Spec 0 outstanding (1 P2 resolved).
