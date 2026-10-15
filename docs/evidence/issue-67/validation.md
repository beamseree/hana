# Capture failure, retry and dismissal safety — issue #67

## Implementation

Capture Session keeps the submitted operation ID on an unchanged retry. Any
payload edit after an attempt (text bytes, capture mode, or task destination)
starts a new operation. Selection changes and choosing the same destination do
not. Text comparison uses UTF-8 bytes, matching the Store's receipt contract even
for canonically equivalent Unicode strings.

While saving, the editor and destination are frozen and the label reads
“Saving…”. Enter cannot issue another save. Escape/outside click records a
dismissal request without discarding the submitted capture or cancelling the
write. The bar stays visible until the result. Escape releases its key status;
an outside click keeps the user's chosen destination. Session observers pause
so subsequent activation notifications cannot discard a retained failure.

Success after a dismissal request closes immediately without confirmation or
origin restoration. Failure leaves the visible, editable text with “Save not
confirmed. Your text is kept. Press Enter to retry.” This wording also covers an
acknowledgment failure after commit. The callback never orders the panel front,
makes it key, or activates an app. Clicking the panel or explicit reinvocation
resumes its session observers. The invocation/operation fence remains in front
of every save outcome; the confirmation timer also checks its invocation.
An unresolved save retains its invocation, so reinvocation reuses the same
capture rather than creating a newer invocation that could receive its result.
The native suite asserts this with the Store write gated. The `finishSave`
invocation/operation fence is inspected defensive protection, not an executed
injection of a stale Store callback.

This is in-memory recovery for an explicit save, not a persisted draft or
protection against process termination. Dismissal before submission still
discards unsaved captures.

## Automated checks

Base revision: `99189854dcb49c4a2b22228ee367e1bb3652ff4d`.
Toolchain: Apple Swift 6.3.3, arm64 macOS 26. Tests use marked temporary collection
roots and never the live collection.

- Red/green: the existing failed-capture test first failed because editing kept
  the old operation, then passed with a new operation.
- Red/green: the deferred-dismissal test first failed because `closeSaved` was
  absent, then passed with the serialized outcome.
- Red/green: changing a failed task's destination first retained its stale error;
  clearing that error on a payload change passed the regression.
- `xcrun swift build`: passed.
- `xcrun swift build -c release`: passed.
- `xcrun swift test --filter 'Capture(Safety|Submission|Session|Task)Tests|CollectionStoreTests'`:
  **64 tests passed in 6 suites**. Includes both capture modes, unchanged retry,
  selection-only edits, changed text and Unicode byte identity, destination and
  mode changes, unknown/committed/failed dismissal outcomes, and duplicate-submit
  suppression. Real temporary Store faults verify a lost commit acknowledgment
  followed by retry creates one item, rollback/edit/save creates only the edited
  item, and a paused transaction stays in saving until its result is delivered.

## Native validation status

Beam handed over the native testing slot on 2026-10-15 after the earlier request
to wait. The automated runs below completed, and the slot was explicitly
released. No production Hana app was installed or launched; these runs presented
test panels through the Swift test executable.

- Tested implementation revision: `a8d3914fc5288c7990f75583b441acf666583866`.
- Environment: macOS 26.4.1 (`25E253`), Apple Swift 6.3.3, arm64.
- `xcrun swift test --filter CaptureSafetyNativeTests`: **3 tests / 10 parameter
  cases passed**, including **12 paused-save dismissal scenarios** (two modes,
  three outcomes, and both Escape and outside click). See [raw output](native-tests.txt).
- The first full-suite run exposed test cleanup in the existing
  `shiftEnterWritesANewLineInNoteAndEnterWithoutACollectionKeepsIt`: the test
  returned before the asynchronous missing-collection failure. Its deferred
  dismissal correctly retained the pending save, leaving that test's panel
  visible and contaminating subsequent editor tests (32 assertions failed).
  Running just that test and `noteKeepsMarkdownPunctuationAsTyped` reproduced
  the retained `one\ntwo` buffer in the next test. The cleanup now waits for the
  failure and verifies the editor is editable before dismissing. Production
  behavior is unchanged.
- `xcrun swift test --filter 'NativeEditingTests|CaptureSafetyNativeTests'`:
  **22 tests passed in 2 suites** after that test-only cleanup. See
  [regression output](native-regression-tests.txt).
- `xcrun swift test`: **297 tests passed in 37 suites**, with **11 opt-in
  live-index/performance tests skipped** by their existing gates. See
  [full-suite summary](full-tests-summary.txt).
- Initial #67 native test executable SHA-256:
  `8e526c2e25750f4da88d4393ff375483d1868ca44b6c887fe4da273f35694f3b`.
- Final regression/full-suite executable SHA-256 (same implementation plus the
  test-only cleanup recorded in this evidence commit):
  `9e4a018328f937cd49190208379fc3ee1ef78142389045cd9a199e5a6f5e22e7`.

The executed suite uses real AppKit panels and a real temporary Store. It covers
Escape and outside-click dismissal with success, rollback, and lost commit
acknowledgment for both Note and Task; saving visibility; frozen input; retained
failure text; unchanged retry; editing after rollback; and an obsolete
confirmation/dismissal leaving a newer invocation intact. A separate key panel
represents the user's later destination, checking key-window/first-responder
state without activating an app. It does not establish physical typing focus
in a foreign application or behavior across Spaces.

Physical checks remain separate: for Note and Task from another app, during a paused save,
Escape/outside click must release keyboard control; success must close without
reactivation, and failure must preserve recoverable text without taking focus.
Human physical observations remain unperformed. On 2026-10-15 Beam requested
that further deep checks stop and that PR #84 be marked ready, with the
automated desktop results and remaining limits recorded below.

## Code review

The code-review skill reviewed Standards and Spec separately against the pinned
base revision. Standards: no actionable findings. Spec: no confirmed code defect
or scope creep; physical validation is the remaining gate. The executed
native test explicitly asserts gated reinvocation preserves the old invocation
and frozen payload; its other stale-callback test is named for the confirmation
timer it exercises.
Both review axes also reviewed the follow-up test cleanup and found no issues.

## Automated desktop input checks — 2026-10-15

With Beam's explicit authorization, a small helper sent global keyboard events
and mouse clicks to dedicated disposable probe windows, rather than selecting
an app immediately before each typed marker. No privacy settings were changed.
A temporary copy of revision `86b674d` used the unchanged Capture Session,
Mac Interaction and Collection Store sources; only its launch bootstrap was
changed to open a marked disposable Store, install pause/failure hooks, and
report fixture state. The production source and PR executable were unchanged.

**18 scenarios passed:** Note and Task × success, rollback and lost commit
acknowledgment, across ordinary Escape, full-screen Escape, and ordinary
outside-click dismissal. Global text arrived in the intended foreign-app
editor both before and after the save result, without activating that app
between the result and the typed marker. Failed captures retained their text
and error; explicit reinvocation and unchanged retry succeeded. The existing
Collection Store fixture interface confirmed **exactly one saved item for
each of the 18 counted captures**. See [scenario summary](desktop-checks.json).

Full-screen outside-click trials did not establish the expected typing
destination and remain **inconclusive**. Calibration attempts and these trials
are excluded from the 18 passes; their disposable records are not treated as
duplicate saves of counted captures. Further testing stopped at Beam's request.
This is automated end-to-end evidence, not a human physical verdict or coverage
of every foreign app/window type or Space transition.

The fixture app and probe were quit, their temporary full-screen window was
closed, and the native testing slot was released. The normal PR build was
restored and launched with diagnostics. Its installed executable SHA-256 is
`d9e5837508844f4662d3508268c46eadabb475a3f3601bf33c202ea52042468b`,
matching the build installed before these checks. Local detailed observations,
temporary helper sources and build identities are retained under the ignored
`build/issue-67-ui-validation/` directory.

## Merge resolution — 2026-10-15

Merged `main` at `ae8bda4` (#68 capture suggestions). Both prefixes and suggestions
use `enterCapture`, with #67's payload-change handling retained after validation.
The combined Capture Session, suggestion and Store tests pass: **68 tests in
7 suites**. The test build also compiled the AppKit suites; native UI tests were
not rerun for this merge resolution.
