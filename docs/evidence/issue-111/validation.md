# Issue #111 — Automatic switch prototype home

Validated 2026-10-15 on `codex/issue-111-automatic-switch-home`, based on
`codex/issue-110-integration` (`f81450a`). The implementation source revision is
`10e4b6762185f581b2aecf63549b2af045bb216f`. The integration and ticket PR target is
`feature/automatic-switch`; this ticket does not change `main`.

## Implementation

The status menu has an Automatic switch (prototype) submenu between Open Hana
and Quit. Its On checkmark persists a typed UserDefaults snapshot, which defaults
to off. A fresh invocation reads the snapshot; reinvocation retains its session.
The table's remaining typed defaults are present for subsequent classifier and
policy tickets, with no classification or automatic switching in this ticket.

The submenu refreshes switch, wrong, reversal, ambiguous, missed, error and timeout
counts and per-classifier median/max latency when opened. Reset Counts appends a
marker and preserves history. It is disabled while off so the off state writes
nothing. Reveal Log asks Finder to reveal the log, or its containing directory if
no log exists.

`AutomaticSwitchDiagnostics.record(_:options:)` accepts a closed event enum;
all payloads are closed enums, booleans or numbers. Its private encoder adds time
and a typed options snapshot. There is no String or arbitrary dictionary input
at the recording boundary. The file is independent of `--diagnostics` and uses
`~/Library/Logs/Hana/automatic-switch.jsonl`, directory mode 0700/file mode 0600.
Existing files/directories have those permissions reapplied. Failures print only
a fixed message. Counts rebuild from JSONL across relaunch and ignore invalid
rows. The manual prefix and suggestion paths record a missed switch only after a
successful Search-to-capture transition with nonblank Search text.

## Automated evidence

- [Initial options red](options-red.txt), [log red](log-red.txt),
  [counts red](counts-red.txt), [interaction red](interaction-red.txt) show the
  vertical public-seam tests failing before each implementation boundary existed.
- [Regression run](regressions.txt): **141 tests in 16 suites passed**, 20.056 s,
  using `xcrun swift test --no-parallel --filter 'AutomaticSwitch|CaptureSessionTests|SuggestionInteractionTests|NativeEditingTests|NoteModeTests|CaptureSafetyNativeTests|MacInteractionTests|MainWindowTests|TaskSaveTests'`.
- [Build](build.txt): debug SwiftPM build passed. `git diff --check` passed.

| Acceptance | Evidence |
| --- | --- |
| Feature target; main unchanged | Ticket branch ancestry includes integration feature tip; orchestrator handles feature-targeted PR/merge. |
| Submenu, persisted off default, no working window/policy change | `optionsDefaultOffAndPersistAcrossStoreInstances`; `submenuPersistsToggleAndResetsCountsWithoutOpeningWorkingWindowsOrChangingPolicy`, through real NSMenu actions. |
| Off writes nothing; existing routes unchanged | `disabledLoggingCreatesNothingAndEnabledScriptNeverRecordsInput`; off native prefix/suggestion cases; existing prefix, suggestion, Enter, save and editing suites pass. |
| Closed recording API and no input in log | Typed `Event`/`Verdict` boundary; scripted Capture Session privacy test and native missed-event file checks, including Thai input. Permissions checked from filesystem. |
| Counts/reset correctness | Script includes saved, reversed, dismissed, late-match return/stay, missed, failure/timeout and two classifiers. Median/max and reset/reopen history asserted through diagnostics API. |
| Prefix/suggestion missed event | Native cases cover Note and Task, both On and Off, via real editor insertions and selected suggestion actions. |

## Test identity and limits

Swift 6.3.3 (`swiftlang-6.3.3.1.3`), arm64, macOS 26.4.1 (25E253).
The native testing slot was exclusively granted to this ticket and released
following the regression run. New native suites use `.nativeWindowSlot` and
`.serialized`; the command also used `--no-parallel`.

Debug build SHA256:

- Hana: `882a13a0bf2df57596291da27434d70e38bf657538a86db890128316849f824a`
- HanaPackageTests: `cb9a95958509ddad7366ead03ccfeb6112fdfe67933163245305248f77fdd63c`

These are automated AppKit action/state and filesystem observations. No installed
app was launched or replaced, no real classifier was invoked, and no human
physical focus, menu appearance, persistence across an installed-app relaunch or
Finder reveal observation is claimed. This ticket builds no classifier or policy.

Evidence text logs escape literal CR, VT, FF and Unicode line-separator test
arguments and trim trailing ASCII whitespace for a clean committed range diff.
Test results and source are unchanged. `git diff --check f81450a...HEAD` was
checked after this normalization.
