# Completed and mixed Archive — #96

2026-10-15, macOS 26.5.1 (25F80), Apple Swift 6.3.3 / CommandLineTools, arm64. Branch starts at `5547a24` after #93 and incorporates current integration `a939092`. All tests use marked disposable fixture Stores at the agreed Mac Interaction boundary; open-note state uses the existing Note Editing session route. The live collection is never opened.

## Behavior

Completed observes the Store's completed-task order. Its checked-circle action reopens at Inbox's top; inline rename and Archive reuse active-task rules, retaining completion. Move, Complete and manual ordering are unavailable in Completed. Reopen has a native Command+Shift+O alternative, and the existing task-menu shortcuts remain distinct.

Archive interleaves committed note/task observations by descending archive time, with deterministic note-before-task/ID ties. Selection identity includes kind. Rows show Note/Task and an archived task's Completed/Unfinished label. Restore preserves note body, pin and content-edited time; unfinished tasks return to Inbox's top, including tasks archived from Today; completed tasks return to Completed. Note restoration uses #93's open-session flush/revision route. Archived notes open read-only and become editable when restored from either surface. No delete action exists.

Restore buttons/context menus and the native Archive menu share the same route. Command+Shift+R restores the selected Archive item; Return opens a selected archived note. Note-window Restore keeps Control+Command+R. A real menu check showed AppKit clearing the duplicated Control+Command+R on the new Archive menu, so Archive uses its own distinct key equivalent. Stale actions preserve committed records and explain the refusal; missing/closed Stores clear Archive rows and disable restoration.

The navigation check confirmed an existing bug: an invalid task rename could remain active after its editor's section disappeared. Sidebar and programmatic section requests now commit before navigating; failed validation keeps the source editor visible. Focus loss/navigation/close share one in-flight rename result. Only the latest requested section proceeds, including canceling pending navigation by selecting the current section. Main-window close holds a rename until commit; invalid drafts stay visible for correction or Escape.

## Recorded checks

`focused-tests.txt`: 46 tests across 9 suites passed in 16.207 seconds, covering all new Completed/Archive behaviors, existing task lists/manual order, main Notes, open-note organization, native note editing and native save lifecycle. All native processes acquire the shared atomic lock and use the external CLT Testing/Interop wrapper with scratch directory `/tmp/hana-spec-88-build-90`.

`CompletedArchiveTests` uses OrganizedCollectionFixture's actual archive/completion combinations through Store reads and live presentations. It verifies Completed ordering/Reopen; native Completed rename and Archive; mixed chronology and labels; every fixture restore; tied kind ordering and Today-to-Inbox restoration; an open archived note restored from either window; stale note/task restore preserving newer committed records; missing/closed availability; and invalid, paused, superseded and close-boundary renames. `red-tdd.txt` retains actual failures before the corresponding fixes. Earlier missing-API compiler failures remain in the external task context.

`native-runtime.jsonl`: the existing signed main-window fixture app reached `main-window.organization` and `main-window.validation-passed`, then exited normally with status 0. Its real AppKit run loop verifies keyboard Reopen, task Archive, Archive Restore and Return opening; read-only note state and session restoration; invalid native main-window close retaining its editor; valid navigation after rename; and valid final native close committing the title before accessory policy. Prior main capture/Escape/minimize/Dock checks also pass. `sign.txt` verifies the isolated bundle. Executable SHA-256: `16cfdc00d01c55f1e04b1545dc8fc2f966b10c8d29ecdbb07b3e5d3cb3d12889`.

## Native feedback-loop diagnosis

The first app-loop run failed at mixed Archive: its trace is retained as `native-failed.jsonl`. `native-state-diagnostic.jsonl` established one archived note, zero archived tasks and the task still in Inbox. Waiting for Reopen acknowledgment did not fix it; `native-acknowledgment-probe.jsonl` records available=true, busy=false and intact menu keys/modifiers. An all-uppercase synthetic event failed earlier at Reopen (`native-uppercase-probe.jsonl`). None is counted as a pass.

The SDK and [Apple's NSEvent documentation](https://developer.apple.com/documentation/appkit/nsevent/charactersignoringmodifiers) distinguish the character fields, retaining Shift for charactersIgnoringModifiers. `native-cg-event-diagnostic.txt` records CGEvent-derived Command+Shift events producing lowercase characters and uppercase charactersIgnoringModifiers. Those native-derived events passed with unchanged product shortcuts. The final harness derives NSEvents from private-source CGEvents and contains no temporary probes. [Apple's modifier documentation](https://developer.apple.com/documentation/appkit/nsmenuitem/keyequivalentmodifiermask) describes equivalent shifted menu forms.

One early combined CLT run exited 0 before a test summary and was not counted. Excluding actual native performClose completed the remaining tests, isolating that helper-runner trigger. The fixture close check now drives Mac Interaction's native delegate and awaits close preparation; actual performClose stays in the existing app-loop harness. The complete 46-test run above and final app-loop are the recorded passes.

## Limits

These are automated fixture events and native state observations. Physical keyboard/input-method use, rendered visual polish, full-screen Space routing and integrated acceptance remain #99. No screenshot or physical acceptance is claimed. This slice adds no persistence schema, deletion behavior or broad new validation harness.

Post-merge primary integration `becc0ee`: `integration-tests.txt` records a fresh-scratch run of 33 tests in 6 suites passing in 9.344 seconds, covering Completed/Archive, prior task lists/manual order, main-window behavior and open-note organization.
