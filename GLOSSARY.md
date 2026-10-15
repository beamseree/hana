# Native macOS search bar — glossary

Language established in the design interview for [product specification](docs/product-spec.md).

## Language

**Search bar**:
The compact entry point for finding notes and tasks, launching apps, and finding files; it can change form to support capture.

**Shapeshifting**:
The search bar's transformation into the interface needed for the current activity; a core part of the intended experience.

**Mode**:
An activity the search bar is in, such as searching, capturing a note, or capturing a task, entered explicitly or by automatic switch.

**Automatic switch**:
A mode change the search bar makes on its own from the text typed in Search, which the user can reverse.
_Avoid_: Auto-mode, smart mode.

**Strong match**:
A search result whose name equals or begins with the Search text, from an app, an active note, an unfinished task, or a file named exactly that text; while one exists, no automatic switch happens.

**Note**:
A separate saved piece of writing within the app's collection.

**Task**:
An item to do, held within the app and capable of being marked complete.
_Avoid_: Todo (use task consistently in design documents).

**Inbox**:
The task list for uncompleted tasks that are not in Today.

**Today**:
The active task list; unfinished tasks remain here across calendar days until completed or moved back to Inbox.

**Unsaved capture**:
Note or task text entered in the bar but not yet saved; dismissing the bar discards it.

**Main window**:
The app's persistent workspace containing Notes and Tasks sections.

**Note window**:
A separate working window for an existing note, where edits autosave.

**Working window**:
An open main, note, or Settings window, including one that is minimized. The search bar is not a working window.

**Invocation origin**:
The app and editing context from which the search bar was opened; the intended typing destination when the bar is dismissed with Escape or closes after a successful save.

**Mode prefix**:
A leading typed symbol that selects a capture mode from Search: `-` for Note and `[` for Task. Pasted symbols do not select modes; a typed mode prefix is not part of the captured content.

**Suggestion**:
A selectable action offered alongside search results. A capture suggestion changes mode only when selected.

**Completed**:
The view containing finished tasks; reopening a task returns it to Inbox.

**Pinned note**:
A note marked for easy access regardless of its position in the recently edited list.

**Archive**:
The collection of notes and tasks deliberately removed from active views and default search, retained indefinitely for restoration. Archiving a task does not mean completing it.
_Avoid_: Trash, deletion.

**Collection**:
All notes and tasks owned by the app, including archived notes and archived or completed tasks.

**Completion state**:
Whether a task is unfinished or complete, independently of whether it is archived.

**Task placement**:
An active unfinished task's membership in Inbox or Today.

**Working display**:
The display containing the focused window when the search bar is invoked, or the display containing the pointer when the focused window's display cannot be determined.

**Full export**:
A portable copy of the entire collection, including the information needed to preserve organization and item status.

**Backup snapshot**:
A recoverable copy of the saved collection at a particular time; it does not include unsaved captures.

**Safety snapshot**:
A backup snapshot of the current saved collection made before replacing it during restoration.
