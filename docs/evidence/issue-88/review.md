# Integration review — #88

2026-10-16, Asia/Bangkok. Independent read-only reviews compared `ced5e5f4fa5d7a9561ae5d298201bb897961882b...1e46fd2f1a440a8e7ca2ba3ef523fdbbf164f09b`. Later integration commits only preserve verification evidence.

## Standards

Reviewed the pinned `ced5e5f…1e46fd2` source/tests/docs diff and full commit list, read-only; no native tests run.

**Documented standards: one low-priority finding.**

- **[P3] Apply the complete typography roles.** `Sources/Hana/MarkdownPreviewRenderer.swift:70–86` reduces each role to `NSFont`, then creates paragraph attributes without `.kern` or the role’s line height. Thus `note.previewHeading` never receives its documented −1% tracking, and wrapped preview prose/code/headings use AppKit’s default leading rather than 22/24/26 points. The source editor similarly only assigns `HanaFont.Note.body.nsFont` at `Sources/Hana/NoteWindowController.swift:66`, omitting its 22-point wrapped line height. Rule: `docs/design-system.md`, Typography Roles/Rules (“Line height is for wrapped text”) and Markdown preview type roles, line 198. Carry the `FontRole` through rendering and apply its tracking/paragraph metrics; configure matching editor typing attributes. This is a documented presentation mismatch, not an acceptance blocker.

**Baseline smells: judgement calls, nonblocking.**

- **Duplicated Code** — “the same logic shape appears in more than one hunk or file.” `Tests/HanaTests/CompletedArchiveTests.swift:313–317` duplicates the recursive `task-title-editor` lookup in `Tests/HanaTests/TaskWorkspaceTests.swift:204–209`. Extract a shared native test helper so changing the editor identifier/tree traversal requires one update. No observed correctness defect.

No other actionable documented-standard violation or listed baseline smell found. The collection boundary remains typed; main-actor AppKit ownership, immutable parser values, revision/generation checks, dependency pinning and glossary terminology are consistent with repository guidance. The explicit light-appearance decision overrides the earlier milestone wording. #99 evidence distinguishes runtime/CUA results from pending physical observations, retains failed probes and the no-argument-launch uncertainty, and leaves ADR0005 proposed; those limitations are reported honestly.

## Spec

Independent Spec review of ced5e5f…1e46fd2 (read-only source/test inspection; no native tests run).

(a) Missing/partial requirements

- **[P2] Drain task renames before allowing quit.** #88: “Inline task rename commits on Return or loss of focus” and “A refusal … keeps the row in editing with the user's text and an explanation.” `Sources/Hana/MacInteraction.swift:532–561` waits for pending capture and note saves, then closes the Store without consulting the organizer's rename draft or `renameSave`. Concrete race: press Return on a valid inline rename, pause its Store transaction, then Quit. `CollectionStore.close()` invalidates ownership immediately, and the pending transaction's final `requireCurrent` refuses it; quit still succeeds, discarding the draft and its failure notice. Await/commit the organizer rename and cancel termination on refusal, as main-window close already does. Current quit tests cover notes/capture only.

(b) Unrequested behavior/scope creep

- No concrete scope-creep finding. Fixture validation machinery supports the requested evidence. Light appearance is Beam's recorded override; pending physical checks and deferred recovery/Search/design work are accurately separated.

(c) Implemented behavior that looks wrong

- **[P2] Preserve independent note-open requests when only focus is superseded.** #88: “Opening a note opens its note window” and “I want each note to open in its own window … so that I can work on several notes side by side.” `Sources/Hana/MacInteraction.swift:476–482` returns before constructing/registering the window whenever another destination has changed `latestWindowOpen`. If two different notes are opened while the first asynchronous Store read is pending, the first requested window never opens. Raising main while a note loads similarly cancels that opening. Apply focus ownership checks to activation/responder changes, while retaining the ordinary note-open request. The newer-capture test proves intentional focus protection but does not cover two independent delayed note opens.

Evidence is candid about CUA drag limitations and remaining human gates; those are not reported as code defects.

Standards: 2 findings, worst P3 incomplete typography roles. Spec: 2 findings, worst P2 pending rename loss and suppressed independent note opening.

## Additional integration inspection

- **P2 — Preserve the task target at the native intent boundary.** TaskWorkspaceView selects a row, then schedules a Task whose perform call resolves mutable selectedID; the menu target similarly defers reading selection/section. Another selection/navigation before execution can retarget Complete/Move/Archive/Rename. Reorder already captures its observed request. Capture each other action’s row ID/revision/section before scheduling and refuse stale requests without acting on a different row.
- **P2 — Scope Note commands to their intended window.** MacInteraction.selectedOrganizerNote reads the background main selection without checking NSApp.keyWindow. Pin/Archive can change an unrelated note while a different note editor is frontmost. Disable organizer-only commands outside main, or route them to the current note; never act on background selection by accident.
- **P3 — Complete menu alternatives.** Notes opening, section navigation and preview toggle have pointer/keyboard paths but no corresponding native menu commands. #88 requires every organizer action from keyboard and menus. Add scoped alternatives without duplicate key equivalents.
- **P2 — Release closed editing sessions.** The Standards reviewer separately observed NoteEditing.sessions retains closed sessions and their full bodies until reopening that same ID/process exit. A long-lived menu-bar app accumulates every distinct long note read. Evict terminal closed/discarded sessions while preserving one shared active session; do not retain an abandoned opening that has no window owner.

All actionable items above are assigned to one implementer branch. Findings are retained separately by axis; disposition and validation will be appended after fixes. Physical acceptance and CUA drag/drop remain accurately pending.

## Implementer dispositions — 2026-10-16

All eight findings plus the additional confirmed closed-note Archive/open race are addressed on `codex/issue-88-review-fixes`, based at exact `6319140`. [Review-fix evidence](review-fixes/validation.md) records each disposition and red/green behavior, including the unsafe weak-only ownership variant that was rejected by an owner-flush regression. The final bounded check passed **68 tests / 14 suites**; original global key/query and scoped native menu assertions remain intact for an unlocked run. Signed app-loop/menu/focus attempts and isolated Capture tests were blocked by an actual locked session (`loginwindow` traces plus root's `IOConsoleUsers` confirmation), not accepted as passes or diagnosed as product/CLT defects. Final full native suite, actual app-loop proof, reviewed release identity and physical acceptance remain root-owned gates after unlock. No Search, backup or design expansion was introduced.

## Independent fix verification

Both reviewers inspected immutable `a17608f` against `6319140` after implementation. [Standards verification](review-fixes/standards-verification.md) and [Spec verification](review-fixes/spec-verification.md) found no remaining actionable finding in the targeted fixes. These were source/test/evidence inspections, not new native test runs. All original findings above remain recorded; final native and physical acceptance gates are separate.
