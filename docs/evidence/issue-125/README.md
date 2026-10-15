# Word-paced withdrawn switches and vetoes — issue #125

2026-10-15. Started directly from integration `daa443a`, including #123,
#124's validated native fixture, and #126. No live Jev API is used by the tests.

## Implemented behavior

- The normalized prefix from the switching answer is the switch point. A
  deletion at the end that leaves a strict prefix withdraws the switch at the
  deletion pause. Emptying automatic capture also waits for this pause.
- Native replacements carry whether their changed range reaches the end.
  Editing earlier in the buffer never withdraws, even when repeated words
  make the resulting text a strict prefix. Ordinary edits that retain the
  switch point keep the mode.
- Backspace at the start and the configured Escape return record a reversal
  and veto the rejected mode while the current text starts with that rejected
  text. Other modes may still switch. Deleting before the rejected text or
  clearing removes the veto. The stop-until-cleared comparison remains.
- Withdrawals rearm classification and the same text can switch from launch
  cache. A late strong match cannot change mode during a deletion burst.
- `autoswitch.withdrawn` and its end reason are distinct from a reversal.
  Counts and the submenu show withdrawn returns separately from wrong switches.

## Settings and historical rows

New Word-paced settings default to **Block that mode for this text**. A saved
legacy `reversalSuspends: true` migrates to **Stop until the bar is cleared**;
`false` migrates to mode blocking. The decoder preserves every other setting,
including the earlier pipeline-to-Word-paced firing migration.

The legacy flag and its menu remain for the other firing strategies, retaining
their behavior. Word-paced shows **After reversing a switch** with the two new
choices. Historical JSONL rows without the new choice continue to decode and
contribute to counts. The log is not rewritten or deleted.

## Policy, migration and diagnostics verification

The agreed seams are policy `handle(event) → [effect]` with `TestClock` and
scripted answers, the options store, and diagnostics recording/counting.

Five red/green slices are retained as `red-1.txt` through `red-5.txt`: missing
withdrawal; a late gate transitioning during deletion; reversal suspending the
other capture mode; the missing settings interface/migration; and an empty
automatic capture returning before its deletion pause. Red-4 is the compile
failure for the missing reversal choice. The final regression is
`policy-green.txt`:

```sh
xcrun swift test --no-parallel --filter 'AutomaticSwitch(Withdrawal|ReversalOptions|WordPaced|WordCache|Deletion|WakeUpTests|Tests|DiagnosticsTests)|JevBackoffTests'
```

Result: **109 tests in 10 suites passed**. The command compiles native tests
but does not execute any native suite.

After syncing integration `2cd1e96` (including #127 and the session-count
review fix), the same selection plus `SessionCount` and `JevHTTPSessionTests`
passed **112 tests in 12 suites** (`integrated-green.txt`). Native tests were
again compiled and excluded from execution.

| Acceptance | Test |
| --- | --- |
| Withdraw at pause, rearm and reuse cache | `deletingPastTheSwitchPointWithdrawsAtThePauseAndRetypingUsesTheCache` |
| End clear also withdraws at pause | `clearingAutomaticCaptureWithdrawsAtThePauseAndRearms` |
| Earlier editing/equal or retained switch point keeps mode | `editingEarlierOrKeepingTheSwitchPointKeepsTheMode`; `theSwitchPointIsTheAnswersPrefixRatherThanTheLaterBuffer` |
| Late gate waits for burst end | `aLateStrongMatchCannotChangeModeDuringTheDeletionBurst` |
| Per-mode veto, both reversal methods | `reversingBlocksTheRejectedModeButAllowsTheOtherCaptureMode` |
| Delete before veto/clear lifts it | `deletingBeforeRejectedTextOrClearingLiftsTheVeto` |
| Stop until cleared | `stopUntilClearedStillSuspendsBothModes`; existing comparison tests now select that choice explicitly |
| Explicit capture does not withdraw | `anExplicitlyEnteredModeNeverWithdraws` |
| Enter eligibility freezes the shown mode | `enterSavingTheShownModePreventsPendingWithdrawal` |
| Preserve legacy settings | `legacyReversalChoicesMigrateWithoutResettingTheSnapshot` |
| Withdrawn versus reversal counts, historical rows, content-free log and reset | `withdrawnReturnsAndReversalsRemainDistinctAlongsideHistoricalRows` |

## Native verification pending integration testing slot

`JevWordPacedWithdrawalNativeTests` uses the real editor, fixture Store,
controlled classifier and `.nativeWindowSlot`. It covers withdrawal while
preserving text and UTF-16 selection, cache reentry, an earlier repeated-word
edit that looks like a strict prefix, Backspace's veto and the other mode,
both Escape options, Enter saving the shown Task exactly once, and the
renamed/migrated menu choice with separate counts.

These cases were **compiled, not run by this implementer**. The integration
agent owns Beam's testing slot and will add native results. No app was
installed. Automated evidence does not establish physical focus, real Jev
latency or classifier quality; Beam's trial remains separate.
