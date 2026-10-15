# Issue #94 — Inbox and Today

2026-10-15, Asia/Bangkok. Mac Interaction is the agreed test seam. All tests use disposable fixture roots and the production Collection Store; no live collection is opened.

## Delivered behavior and design slice

Inbox and Today observe the Store's own queries and manual order. A capture or external Store commit appears without refreshing. Today is stored membership, with no calendar timer. A selected task can be completed, moved to the top of the other list, archived, or renamed. All mutations carry the row's revision. Failed commands explain the failure and never invent a successful transition.

The existing sidebar, window chrome, heading and list geometry remain in use. Task rows use `surface.group`, `body`, primary text and the design system's faint unchecked circle. The native inline editor uses `surface.card`, `body` and the primary insertion-point color; explanations use `detail` and `status.error`. There are no new raw color/font values or painted window shadows. The row's circle completes it, double-click starts renaming, and every action also appears in the row context menu and the native Tasks menu. Keyboard engineering defaults are Command-Shift-K (complete), Command-Shift-T (Today), Command-Shift-I (Inbox), Command-R (rename), and Command-Shift-A (archive). Return on the selected list row also begins renaming. Menu validation disables task commands while text editing or another window/bar owns keyboard input.

The inline title is a retained AppKit `NSTextView`. Return or focus loss commits; Escape discards the draft. A blank commit keeps the draft/editor with a notice. Any mandatory line break in a native insertion, including a real multiline paste, is rejected whole, preserving the previous title and selection. Programmatic invalid drafts are also refused by submission and the Store. A stale rename reloads the committed row/revision, retains the user's draft and explains the competing saved title; only another explicit Return retries against the new revision. No stale draft overwrites a competing edit automatically.

## Automated checks

- `initial-red.txt` records the first missing task presentation boundary; `native-red.txt` records the missing native inline editor before it was implemented. Subsequent vertical slices also went red for absent action/rename/menu APIs before their implementation.
- `focused-tests.txt` records 22 passing tests in Task Workspace, Main Window, and task lifecycle suites (including the parameterized native command cases). Task Workspace covers live order/new top insertions, Store-close unavailability, complete/move/archive operation-table state, exact draft preservation, blank/multiline refusal, stale reload and explicit retry, cancellation, synthetic native Return/Escape key events, native focus-loss commit, actual general-pasteboard multiline paste, and menu command routing/shortcut declarations.
- After merging integration tip `ead807c` (#90), `merged-tests.txt` records 14 passing tests across Task Workspace, Main Window and Notes organization. The additive shared window/menu conflicts retained both features.
- Main Window regression checks cover Notes, unavailable collections, singleton reuse, section selection, minimized membership and existing menus. Task lifecycle checks retain the Store's exact completion/archive/placement rules.

Commands use an independent SwiftPM scratch directory and acquire the shared native process slot with atomic `mkdir /tmp/hana-spec-88-native-lock`. This host's Command Line Tools require `-F /Library/Developer/CommandLineTools/Library/Developer/Frameworks` for compilation/linking and runtime rpaths to that directory plus `../usr/lib` for Testing and its interoperability library. The initial missing-Testing-module/runtime-path attempts were environment setup failures, not product failures; no global toolchain setting was changed.

## Limits

The runner checks native AppKit text operations and registered windows, not physical keystrokes, ordinary app activation, full-screen/Spaces, IME candidate composition, or a human visual acceptance. The integrated #99 app-loop harness owns the wider working-window checks. This slice does not implement manual reordering (#95), Completed/Archive views (#96), or alter the Store's schema. No issues are manually closed; closure follows the integration PR.
