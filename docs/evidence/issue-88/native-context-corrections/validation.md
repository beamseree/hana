# Native context corrections — #88

2026-10-16, Asia/Bangkok. This follow-up preserves the unlocked failures recorded by root under issue #99. It addresses the measured restore handoff and the two native-context tests without weakening their assertions, skipping tests, or modifying the installed application/live Collection/TCC. All native processes used the external atomic slot, marked disposable collection roots and correctly launched signed fixture apps.

## Note restore: measured cause and correction

The unchanged reviewed release failed NoteWindowValidation at `keyboard-archive`. Three hypotheses were considered before probes: delayed Escape/Dock focus restoration; background editor editability changes during Pin; or an overly early organization/menu acknowledgment or synthetic shortcut representation.

Fixture-only probes added a note `didBecomeKey` stack observer and content-free key/organization/menu eligibility markers around Pin/Archive. `note-focus-probe-hashes.txt` identifies that interim source and binary. Outcomes:

- `note-focus-probe-original.jsonl`: original minimize/restore/bar/Escape sequence failed Archive. The unexpected re-key stack is AppKit `windowDeminiaturizationResponse` → `_doRestoreComingFromDock` → `_prepareToRestoreRegularFromDock` → `makeKeyAndOrderFront`. At Pin completion and before Archive, both organization flags were false; note was key, main was not, and Archive was correctly ineligible.
- `note-focus-probe-no-transient.jsonl`: the same Pin/Archive sequence without minimize/restore/bar passed the entire validator. Background editability updates alone did not reproduce the jump.
- `note-focus-probe-cg.jsonl`: CGEvent-derived shortcuts reproduced the delayed Dock re-key and correctly refused the ineligible Archive shortcut. Manual character fields and a lingering busy flag were not the cause.

Previously, opening a minimized working window called `deminiaturize` and immediately `makeKeyAndOrderFront`. That prematurely satisfied the harness's unchanged `!isMiniaturized && keyWindow` check before AppKit finished its Dock restore response, which later reclaimed key focus after a newer main-window request. Main and note opening now activate and request deminiaturization without the redundant early key request; ordinary nonminimized opening still explicitly makes key. There is no timer, private API or later focus reclamation.

`note-focus-handoff-probe.jsonl` passed the original sequence with main key and Archive eligible throughout Pin completion/Archive. All diagnostic source and probe switches were then removed. **`note-window-handoff-final.jsonl` records the uninstrumented signed fixture passing all original minimize/raise, Escape responder, Pin/Archive/Restore, menu, retained final-save and activation-policy checks with normal exit 0.** Hashes are in `native-context-final-hashes.txt`. This does not replace Beam's physical acceptance.

## Swift Testing host: measured limitation and exact assertions retained

Adding an async wait for main key did not fix the isolated menu test (`readiness-menu-probe.txt`, complete failure). Before and after a bounded CFRunLoop-only probe, the host reported `active=false`, `running=false`, `keyMain=false`; that probe also failed with a complete summary. Dispatching exactly two pending type-13 AppKit events made the host active and main key, after which every original menu assertion passed; the earlier deliberately recorded readiness failure remained (`readiness-app-event-probe.txt`).

A proposed narrow pending-event readiness helper instead caused the async-main runner to exit 0 without a summary. Those incomplete runs are retained as failures of verification, never passes. A single bounded LLDB exit probe (`readiness-exit-stack.txt`) stopped at `_swift_exit` ← `swift_task_asyncMainDrainQueue` ← generated `Runner.main`, without an NSApplication termination path. No host delegate or product activation workaround was added, and the event-drain helper/probes were removed.

Only the two affected Swift Test bodies now use `NativeAppFixture`, a test-only process adapter to the existing actual NSApplication validators. It copies the adjacent already-built Hana product and existing App resources into a fresh temporary app, sets a unique test bundle identity, signs ad hoc, and always passes explicit validation arguments. A 20-second timeout and cleanup act only on its owned child. No environment override can select a different executable.

- MainWindowValidation contains the exact original no-selection disabled check, selected menu enablement, `p`/`a` key equivalents with Control-Command masks, Pin, `Unpin Note` title, Unpin, Archive removing the sole row, and Archive disabled afterward. Its dedicated success marker occurs only after these assertions. The seed is then restored for the rest of the existing validator.
- OpenNoteCaptureValidation retains the exact real invocation token, global key/first responder, `new query` preservation and absence of the superseded destination window. Its existing `newer-bar` marker occurs after those assertions.

The adapter requires normal child exit 0, the specific assertion marker, the entire validator's success marker and no validation-failed event. It prints the signed child binary SHA-256. **`native-app-adapter-final.txt`: 2 tests / 2 suites passed in 6.464 seconds with a complete summary**, including those exact app-loop assertions. The test names/count remain; nothing is skipped or replaced with a local responder/fake-key assertion. The added process/signing cost is bounded and confined to these two native-context checks.

Root owns the next merged broad suite, rebuilt release identity and final physical/native smoke. Earlier failed full suites, locked-session attempts and the CUA drag limitation remain part of the evidence; no unrelated search, backup, Settings or design change was introduced.

## Exact hidden-panel assertion follow-up

Spec review identified one omitted assertion while comparing the original Swift test with the app-loop adapter. The delayed invocation-bound capture fixture now retains `originalEditor` and requires `originalEditor.window?.isVisible == false` after opening the destination and before presenting the newer bar. The global key/responder/query/no-window guards and final success markers are unchanged. The process adapter now prints only a `validation-failed` diagnostic event before reporting a failed child exit, so its failed step remains visible after temporary-child cleanup.

The first focused two-test attempt completed with menu passing and capture child exit 1 (`native-app-adapter-hidden-panel-final.txt`); its deleted child trace means the failed step is unknown, and this attempt is retained as a failure. The isolated capture run then passed 1/1 in 2.587 seconds (`native-app-adapter-hidden-panel-diagnosis.txt`). The final combined check passed **2 tests / 2 suites in 6.249 seconds** with complete summary and both exact native assertion markers (`native-app-adapter-hidden-panel-green.txt`); that log records the signed child hashes. No production behavior changed in this follow-up. Root owns the fresh complete suite and rebuilt release checks after integration.
