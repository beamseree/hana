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

`CaptureSafetyNativeTests` compiles but has **not been run**. Beam requested
“Keep working; wait on native tests” on 2026-10-15. No native testing slot has
been taken and no app has been installed or launched for this issue.

The prepared suite uses real AppKit panels and a real temporary Store. It covers
Escape and outside-click dismissal with success, rollback, and lost commit
acknowledgment for both Note and Task; saving visibility; frozen input; retained
failure text; unchanged retry; editing after rollback; and an obsolete
confirmation/dismissal leaving a newer invocation intact. A separate key panel
represents the user's later destination, checking key-window/first-responder
state without activating an app. It does not establish physical typing focus
in a foreign application or behavior across Spaces.

Pending explicit native handover:

```sh
xcrun swift test --filter CaptureSafetyNativeTests
xcrun swift test
```

Also physically check Note and Task from another app: during a paused save,
Escape/outside click must release keyboard control; success must close without
reactivation, and failure must preserve recoverable text without taking focus.
Those observations are pending, so the issue is not marked complete or ready.

## Code review

The code-review skill reviewed Standards and Spec separately against the pinned
base revision. Standards: no actionable findings. Spec: no confirmed code defect
or scope creep; native/physical validation is the remaining gate. The prepared
native test explicitly asserts gated reinvocation preserves the old invocation
and frozen payload; its other stale-callback test is named for the confirmation
timer it exercises.
