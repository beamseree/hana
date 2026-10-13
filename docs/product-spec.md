# Native macOS shapeshifting search bar

Per Beam, 2026-10-13: wants to explore building a native macOS search bar combining Alfred-style search, Things-style todos and quick jotting, Aninote-style scratchpad notes, and a bar that transforms into the interface needed for the current action.

Reference supplied by Beam: https://lab.anishfn.ink/shapeshift

## Goal

A personal native macOS app for quick capture without leaving the current activity, with tasks and notes together rather than scattered across apps.

## Status

Beam confirmed the complete product scope on 2026-10-13 and requested a dedicated project directory. The grilling interview is complete. This project currently contains design documentation only; no app implementation has been created. Technical validation and implementation choices remain separate from the accepted product behavior.

## Confirmed decisions

Per Beam's answers on 2026-10-13:
- Build for Beam first.
- Prioritize quick capture without leaving the current activity.
- Tasks and notes live in this app. This supersedes Boji's initial suggestion to keep commitments in an existing task system.
- Shapeshifting is core to the idea, not optional polish.
- The search bar is the transforming entry point. A main window has Notes and Tasks sections, and individual notes can open in separate working windows.
- Explicit modes with automatic suggestions are accepted. Beam eventually wants to explore what he calls "system one models," citing Typesafe's Jev, for suggestions/classification; this is a future exploration, not a selected dependency or verified capability.
- First-version search must also launch Mac apps and find files, superseding Boji's app-content-only recommendation.
- Notes are separate items, not one continuous scratchpad.
- Do not save unfinished captures as drafts for now. Escape or clicking outside discards unsaved quick captures without confirmation (accepted Q11). Existing notes autosave edits in working windows.
- Initial task scope: inbox, Today view, completion, and moving tasks into/out of Today. Further scheduling/project features are outside the accepted initial scope.
- Global invocation opens Search by default. The empty bar shows only the input, with no mode hints or results; this supersedes the earlier visible-shortcut-hints proposal (Q35). Mode switching retains typed text (accepted Q10 recommendation).
- At the start of Search input, `-` switches to Note and `[` switches to Task. The prefix becomes a visible mode label rather than saved content. Prefixes are recognized only in Search; explicitly switching back to Search allows literal searches beginning with those symbols (accepted Q16, with Beam replacing the proposed `+` task prefix).
- Note mode expands to a multiline writing surface. Task mode becomes compact task entry with an Inbox/Today selector.
- In quick note capture, Enter saves and Shift+Enter inserts a newline, replacing Boji's earlier proposed Cmd+Enter save shortcut. Existing note windows use Enter for newlines and autosave. Task titles remain single-line (accepted Q23).
- Successful capture shows brief confirmation, closes the bar, and returns focus to the prior app. Failed saves keep entered text available (accepted Q18).
- New tasks default to Inbox.
- Enter on a search result launches an app, opens a file in its default app, opens a note's working window, or reveals a task in the main window's Tasks section (accepted Q22).
- File search by filename is sufficient initially; searching file contents is outside initial scope.
- Notes support plain text and Markdown. The first nonempty line supplies the default title (accepted Q13 recommendation).
- Unfinished tasks remain in Today across days; moving them out returns them to Inbox (accepted Q14 recommendation).
- First version is local to this Mac with durable storage and export; no accounts or cross-device sync.
- Markdown syntax stays visible while writing, with optional rendered preview in note windows.
- Automatic suggestions are selectable actions alongside search results and never switch modes automatically. Selecting a capture suggestion transforms the bar; explicit prefixes switch immediately.
- Beam wants file search like native Spotlight or Alfred, rather than the proposed initial folder-selection setup. Apps and files appear together in ordinary search, alongside notes/tasks, with type labels and optional filters. Filename-only matching remains accepted; exact accessible/indexed file coverage needs technical validation.
- Notes are sorted by most recently edited with optional pins; folders and tags are deferred.
- Completed tasks have a Completed view and can be reopened to Inbox. They are excluded from default search, with an explicit option to include them (accepted Q28).
- Archive hides notes/tasks from active views and default search, preserves them indefinitely, and supports restoration through an Archive view. Archive is separate from Completed; no permanent deletion initially.
- Export individual Markdown files for notes and JSON for tasks, including task text, status, and timestamps.
- Search prioritizes strong name/title matches, then uses recency/frequency for similar matches. Creation suggestions sit below actual matches (accepted Q31 recommendation).
- Configurable global shortcut, starting with Option+Space, plus menu-bar access while working windows are closed. Invocation opens the bar on the working display with immediate typing focus (accepted Q32 recommendation).
- Native macOS appearance with a solid white, opaque surface, rounded shape, and system typography. This replaces Boji's translucency proposal. Smooth shapeshifting preserves the input position, expanding around it, while typing remains responsive (accepted Q33 with correction).
- Maintain recoverable automatic local backups in addition to export. Backups do not retain discarded unsaved captures.
- Prefix recognition applies only to typing at the start of Search, never to pasted text; pasting retains the current mode.
- Restoring an archived task preserves completion state. Unfinished tasks restore to Inbox, even if previously in Today; completed tasks restore to Completed. Notes restore to the notes collection.
- Tasks support inline title editing and manual ordering in Inbox and Today, with new tasks at the top. Descriptions, checklists, and subtasks are deferred (accepted Q38).
- Export includes the full collection, including archived and completed items. Note Markdown files have a metadata manifest preserving status and pins; task JSON preserves status and timestamps (accepted Q39).
- Open in window saves a quick note capture and opens its note window; subsequent edits autosave.
- Switching a multiline note capture to Task is blocked until the content is reduced to one line; the note remains intact with an explanation. Never silently flatten or drop content.
- Automatic backups retain daily local snapshots for 30 days. Settings supports restoring a snapshot, with a fresh safety snapshot before replacement so the restoration can be reversed.
- Position the bar horizontally centered in the upper portion of the focused window's display. If that display cannot be determined, use the display containing the mouse pointer. Beam accepted Q43 and asked for clarification of this fallback; explanation supplied in chat. Preserve the input position during expansion, adjusting only to stay onscreen.
- Technical-design clarification, 2026-10-13: working windows must appear in the Dock and Command-Tab. Beam's final correction replaces his earlier menu-bar-only answer; menu-bar access and global invocation remain available when working windows are closed. The process/activation-policy implementation remains subject to native validation.

## First-version acceptance

Accepted Q44, 2026-10-13. Verify the complete loop on Beam's Mac:
- Invoke from another app with immediate keyboard focus.
- Launch an app and find/open a file through mixed search.
- Capture a note and a task, including the typed prefixes and save/discard rules.
- Organize the saved items in the main window and edit a note in its separate window.
- Reopen saved content through search.
- Verify persistence across restart, full export, and backup restoration.
- Verify smooth opaque-white shapeshifting and correct return to the prior app after capture.

These are requirements, not verified implementation results.

## Research evidence

- Checked 2026-10-13: [Alfred Default Results](https://www.alfredapp.com/help/features/default-results/) documents configurable file types in ordinary results and recommends limiting them to essentials. [Alfred File Search](https://www.alfredapp.com/help/features/file-search/) documents Space/open/find as ways to broaden file search. Thus separation is configurable product behavior, not a requirement preventing mixed app/file results. Boji infers the practical trade-off is reducing result clutter and making intent clearer; mixing requires careful ranking.

## Remaining implementation work

- Validate actual indexed file coverage, access permissions, search performance, and focus/display behavior on the target Mac.
- Validate the selected framework/storage design and backup mechanics in [technical design](technical-design.md); resolve the proposed activation-policy implementation through a native prototype.
- Detail filter controls, non-prefix keyboard shortcuts, animation timing, and layouts during implementation/design review. These details have not been silently approved by the product interview.
- Shared understanding is confirmed. Continue with technical design and validation in the dedicated project directory.

## Codebase

The interview created no code. Subsequent work added an isolated native prototype; GitHub tracker setup on 2026-10-13 established the repository below. No production app scaffold exists.

| Field | Value |
| --- | --- |
| Local path | `/Users/beamsereeyothin/Documents/Projects/hana` |
| Working branch | `main` for project documentation and tracker setup; `prototype/window-focus` for the isolated experiment |
| Remote | Private GitHub repository: [beamseree/hana](https://github.com/beamseree/hana) |
| Stack | AppKit/SwiftUI and SQLite through GRDB selected in technical design; no implementation yet |

## Related

- [Glossary](../GLOSSARY.md)
- [ADR 0001](adr/0001-own-tasks-and-notes.md)
- [Technical design and phased validation plan](technical-design.md)
- [ADR 0005 — Proposed activation-policy implementation](adr/0005-activation-policy-and-working-windows.md)

## Log

- 2026-10-13: Initial idea captured; first interview round settled audience, core job, data ownership, and two interaction surfaces.
- 2026-10-13: Second round accepted explicit modes with suggestions, app/file search, separate notes, no drafts, and minimal task scope. Model-assisted classification remains future exploration.
- 2026-10-13: Third round accepted Search on invocation, discarding unsaved quick captures on dismissal, filename search, plain text/Markdown notes, unfinished Today rollover, and local storage with export. Beam proposed a note prefix such as `-`.
- 2026-10-13: Fourth round settled prefixes (`-` Note, `[` Task), mode-specific forms, Enter-to-save/Shift+Enter newline, Inbox default, main window plus separate note windows, existing-note autosave, and search result actions.
- 2026-10-13: Fifth round accepted normal newlines in note windows, single-line task titles, optional Markdown preview, selectable suggestions, recent notes/pins, Completed/reopening behavior, and Markdown/JSON export. Beam requested Spotlight/Alfred-like file search and Archive instead of Trash.
- 2026-10-13: Sixth round settled recoverable Archive without deletion, mixed filtered results, configurable shortcut/menu bar, solid white native appearance (not translucent), and automatic local backups. Verified Alfred permits additional file types in default results.
- 2026-10-13: Seventh round settled input-only empty Search, typed-only prefix recognition, archive restoration destinations, inline task editing/manual ordering, and full-collection export. No empty-state mode hints.
- 2026-10-13: Eighth round accepted saving a capture into a note window, lossless blocking of multiline-to-task switching, 30-day daily snapshots, focused-display placement with pointer-display fallback, and the end-to-end acceptance loop. Awaiting final shared-understanding confirmation.

- 2026-10-13: Beam confirmed shared understanding and requested the dedicated project directory. Working documentation now lives there; this vault retains the interview record.
- 2026-10-13: Technical architecture documented separately. Beam clarified that working windows need Dock and Command-Tab access, superseding his earlier menu-bar-only answer in that design session. No app code or native prototype was created.

- 2026-10-13: Set up the private `beamseree/hana` GitHub repository and Issues tracker. Existing product scope is unchanged.

- 2026-10-13: Renamed the GitHub repository to `beamseree/hana` and the local project folder to `hana`. A compatibility symlink at the former local path keeps existing chats usable. Product scope is unchanged.
