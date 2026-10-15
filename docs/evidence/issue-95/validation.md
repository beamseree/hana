# Issue #95 — Manual task order in Inbox and Today

2026-10-15, Asia/Bangkok. The ticket branch began exactly at integration `bd52158`. Tests use the agreed Mac Interaction seam and marked disposable fixture Stores.

## Delivered behavior and design slice

A task can be dragged before another task or into the empty drop area at the end of its own list. A one-point line in the existing `focus.ring` role marks the target insertion edge. Native SwiftUI drag-and-drop uses a custom Codable transfer representation containing task IDs, placement and the order visible at drag start; it contains no title text. Another list cannot accept that placement. Reordering is disabled during inline title editing and an outstanding task action.

Move Up and Move Down appear in both row context menus and the Tasks menu, with Command-Option-Up and Command-Option-Down as keyboard engineering defaults. They are disabled at the first and last position respectively. Menu/context-menu callbacks freeze the observed list synchronously before starting asynchronous work. There is no optimistic local reordering.

Both paths submit the Store's `reorderTask` with the same `expectedOrder` that belonged to the original gesture or command. A `staleList` refusal reads the latest committed query, refreshes presentation and explains that nothing moved. The stale request is never retried automatically or rebased onto newly arrived tasks. Store observation supplies committed ordering after success. Inbox and Today keep independent orders, and the persisted order survives reopening.

## Automated checks

- `keyboard-red.txt` and `drag-red.txt` record missing keyboard and drag boundaries before their respective implementations.
- `focused-tests.txt` records 18 passing tests across three suites and covers keyboard ordering, first/last boundaries, independent lists, close/reopen, drag-to-top and drag-to-end, cross-list refusal, real native menu action routing, shortcut declarations, and editing taking precedence.
- The race test runs a frozen keyboard and drag request against each interleaved creation, move into Inbox, move out of Inbox, and completion. It waits for the new observation before submitting the old request, proving the request retains its original order even after refresh. Each refusal leaves the full Collection unchanged, with every visible and saved task present at most once. There is no retry that could place the task among unseen entries.
- Existing Task Workspace tests and the Store's Task Ordering race/integer-key/transaction tests run alongside these checks.

Commands use `/tmp/hana-spec-88/test`, an independent SwiftPM scratch directory, and the atomic `/tmp/hana-spec-88-native-lock` slot for every native execution. No live collection, global toolchain setting, issue status or PR is changed.

## Limits

These checks exercise drag and keyboard intents through Mac Interaction and native menu dispatch. They do not synthesize a physical mouse drag through the SwiftUI transfer pipeline, establish human visual acceptance of the insertion line, or prove physical keyboard focus/full-screen/Spaces behavior. Those interactive and app-loop checks belong to the integrated #99 evidence. No cross-list dragging or new Store/schema behavior is introduced.
