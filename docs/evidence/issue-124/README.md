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

## Native evidence pending integration run

`JevWordPacedDeletionNativeTests` uses the real editor, a disposable fixture
Store, a controlled Jev fake whose replies can arrive after cancellation, and
the coordinated `.nativeWindowSlot` trait:

- `nativeDeletionHoldsApplicableAnswersAndPreservesTextAndSelection`, with
  synthesized ⌫, ⌥⌫, and ⌘⌫ commands, including Thai text and UTF-16 selection.
- `enterImmediatelyAfterDeletingUsesSearchAndALateAnswerCannotStealIt` checks
  Search's New note action, no save, and the pending Task answer being ignored.
- `replacingASelectionThatLooksLikeAnAppendStillHoldsTheAnswer` checks native
  replacement-range provenance instead of guessing from the resulting text.

The implementer did **not** run native tests or install an app. The integration
agent owns Beam's granted testing slot and will append native results there.
These tests do not establish physical focus, wall-clock Jev latency, or
classifier quality; those remain the trial.
