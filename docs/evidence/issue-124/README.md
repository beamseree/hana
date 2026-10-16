# Word-paced deletion bursts — issue #124

2026-10-15. Based on the #122 tracer (`37bac99`). This ticket adds deletion
bursts in Search; withdrawal and veto after a switch remain #125.

## Automated policy evidence

The agreed policy seam is `AutomaticSwitch.handle(event) → [effect]`, with
`TestClock`, scripted verdicts, and launch memory. No real Jev request is used.

Six red/green slices first reproduced: an answer switching during deletion,
held answers lost on the next deletion, consecutive held answers losing
agreement, missing replacement provenance, a correction boundary losing its
pause send, and a newer failure allowing an older held answer to switch.
The red runs are `red-1.txt` through `red-6.txt`; red-4 is the compile failure
for the missing edit input. The final regression run is `policy-green.txt`.

Command:

```sh
xcrun swift test --no-parallel --filter 'AutomaticSwitch(Deletion|WordPaced|WakeUpTests|Tests|DiagnosticsTests)'
```

Result: **70 tests in 5 suites passed**. Native tests were compiled by this
command but were excluded from execution.

After merging integration `cd5546d` with #123, the same filter plus
`WordCache` passed **86 tests in 6 suites** (`cache-merge-green.txt`). The merge
keeps edit-time cache lookup outside the deletion burst and preserves each
held answer's one-time confidence count.

| Acceptance | Test in `AutomaticSwitchDeletionTests` |
| --- | --- |
| Holding Backspace sends nothing | `holdingBackspaceSendsNothingUntilThePause` |
| No mode change during a burst | `aQualifyingAnswerWaitsUntilTheDeletionPause` |
| Recheck held answers against final text | `heldAnswersAreRecheckedAgainstTheFinalText` |
| Preserve consecutive held agreement | `twoConsecutiveHeldAnswersCanAgreeAtThePause` |
| Newer failure wins | `aNewerFailureDiscardsAnOlderHeldAnswer` |
| Replace selection/autocorrect starts a burst | `nativeReplacementStartsABurstEvenWhenTheTextLooksAppendedOrUnchanged` |
| Only removed requests cancelled | `onlyRemovedRequestsAreCancelledAndCancellationHasNoLatencyOrContent` |
| Send again at pause and later boundaries | `aWordBoundaryDuringACorrectionWaitsForThePauseThenSendingResumes` |
| Clear resets confidence and suspension | `clearingResetsConfidenceAndNavigationSuspension` |
| Held Enter cancels remaining work and discards held answers | `enterHoldingAnOpenDiscardsHeldAnswersAndCancelsRemainingRequests` |
| Content-free diagnostics; cancelled latency absent | `onlyRemovedRequestsAreCancelledAndCancellationHasNoLatencyOrContent`; existing `sessionRecordsRequestsSentAndCancelledRequestsAddNoLatency` |

## Native verification

`JevWordPacedDeletionNativeTests` uses the real editor, a disposable fixture
Store, a controlled Jev fake whose replies can arrive after cancellation, and
the coordinated `.nativeWindowSlot` trait:

- `nativeDeletionHoldsApplicableAnswersAndPreservesTextAndSelection`, with
  synthesized ⌫, ⌥⌫, and ⌘⌫ commands, including Thai text and UTF-16 selection.
- `enterImmediatelyAfterDeletingUsesSearchAndALateAnswerCannotStealIt` checks
  Search's New note action, no save, and the pending Task answer being ignored.
- `replacingASelectionThatLooksLikeAnAppendStillHoldsTheAnswer` checks native
  replacement-range provenance instead of guessing from the resulting text.

The initial implementation compiled these tests without running them. The
integration run then exposed a fixture error in the Enter case: the empty
Search source finished without publishing a terminal `.ready` batch. Enter
correctly remained held waiting for Search to settle. The focused original
scenario and a one-character minimized correction reproduced that failure
(`enter-native-red.txt`, `enter-native-min-red.txt`). Changing only the fixture
to publish an empty `.ready` batch made the minimized case pass
(`enter-native-min-green.txt`). The original Thai-text scenario was restored,
with an explicit selected New note precondition.

Under Beam's granted native testing slot, based on integration `11565cf` plus
the fixture correction:

```sh
xcrun swift test --no-parallel --filter JevWordPacedDeletionNativeTests
```

Result: **3 tests in 1 suite passed** (five parameter cases), recorded in
`native-green.txt`. The slot was released after the run. No app was installed.
The fix changes test setup only; no product behavior was altered for this
timeout. These tests do not establish physical focus, wall-clock Jev latency,
or classifier quality; those remain the trial.

## Final integration validation — 2026-10-15

At `b31ae3260922790218cbbf7f38b51a62c7573311`, `xcrun swift test --no-parallel` passed with **491 tests in 66 suites** (74.511 s), including all native Word-paced tests. Eleven unrelated environment-gated live-index checks remain skipped. This supersedes earlier native-unrun status in this ticket’s initial implementation phase. [Combined record and logs](../issue-120/validation.md). Physical focus, perceived/live latency and normal-use quality remain #128/#115 human evidence.
