# Word-paced single agreement

Implemented 2026-10-26 at Beam's request: "Agreeing verdicts needed: 1" now switches Word-paced on a single answer at or above the threshold. Source is the local change on baseline `63e413012f013ce5d7b6889e1b2100049ca6217d`.

## Change

This supersedes #123's 0.90 floor. Previously, Word-paced required two consecutive agreeing answers for any answer below 0.90, whichever option was set. Because Word-paced never resends the same text, a short capture (for example `buy milk` answered as Task 0.80) received one answer and stayed at `agreement 1/2` without switching.

The option now applies to every strategy the same way:

- **1:** an answer at or above the threshold switches at once.
- **2:** two consecutive answers must agree, under the unchanged #123 rules. The second answer still comes from the next answer for the same text or its continuation, never a resend. Disagreement, unsure, below-threshold and replacing the previous answer's words still break agreement.

The threshold, multiline Task guard, reversal vetoes, gate and submission rules are unchanged.

## Automated verification

On 2026-10-26, Apple Swift 6.3.3, arm64 macOS 26.4.1:

```sh
xcrun swift test --no-parallel --filter 'AutomaticSwitch|ClassifierMenu|CalculationAutomaticSwitch'
```

**Passed: 153 tests in 19 suites.** Full output: [policy-tests.log](policy-tests.log). The filter also ran the native `AutomaticSwitchInteractionTests`, `AutomaticSwitchDebugInteractionTests`, `AutomaticSwitchWakeUpInteractionTests` and `CalculationAutomaticSwitchInteractionTests` suites, which passed.

The full suite was not run. The native `JevWordPaced*NativeTests` and `JevSubmissionNativeTests` were not run. All of their fake replies use 0.95, which switched at once before and after this change.

| Behavior | Tests |
| --- | --- |
| With 1, answers at 0.70, 0.80, 0.89, 0.90, 0.95 and 1.0 switch at once | `AutomaticSwitchWordCacheTests.oneAgreeingVerdictSwitchesAtOnceAtOrAboveTheThreshold` (replaces `clearAnswersSwitchAtOnce`) |
| With 1, a 0.80 full-text Task answer saves on Enter | `AutomaticSwitchSubmissionTests.aSingleModerateConfidenceAnswerSavesWithOneAgreeingVerdict` |
| With 2, a single answer does not save on Enter | `AutomaticSwitchSubmissionTests.aSingleAnswerDoesNotBypassTwoAgreeingVerdicts` |
| With 2, reusing the same answer on Enter cannot manufacture agreement | `AutomaticSwitchSubmissionTests.reusingTheSameAnswerOnEnterCannotManufactureAgreement` |
| With 2, agreement waits for the next answer without resending | `AutomaticSwitchWordCacheTests.twoAgreeingClearAnswersDoNotResendTheSameText`, `AutomaticSwitchWordPacedTests.secondAgreeingVerdictComesFromTheNextAnswerNeverAResend` |
| With 2, agreement is recorded while Search sources settle | `AutomaticSwitchWordCacheTests.consecutiveAnswersAgreeWhileSearchSourcesAreStillSettling` |
| With 2, disagreement, unsure and below-threshold answers break agreement | `AutomaticSwitchWordCacheTests.disagreementRequiresANewConsecutivePair`, `unsureAndBelowThresholdAnswersBreakAgreement` |
| With 2, replacing the previous answer's words breaks agreement | `AutomaticSwitchReviewPolicyTests.replacingThePreviousAnswersWordsBreaksAgreement` |
| Debug footer shows `agreement 1/2`, then `switched · agreement 2/2` | `AutomaticSwitchDebugTests.agreementAndWaitingForSourcesShowTheActualAnswer` |

The tests that previously relied on the 0.90 floor now set the 2 option explicitly, so they keep covering the agreement rules. `aBorderlineAnswerWaitsForTheNextAgreeingAnswerWithoutResending` was removed: under the 2 option it duplicated `twoAgreeingClearAnswersDoNotResendTheSameText`.

## TDD record

Before the change, `oneAgreeingVerdictSwitchesAtOnceAtOrAboveTheThreshold` failed for 0.70, 0.80 and 0.89 and passed for 0.90 and above: [single-agreement-red.log](single-agreement-red.log).

## Installed build

At Beam's request on 2026-10-26, pre-built the release configuration, then acquired the shared native slot, retained a copy of the previous installed bundle, quit the running installed Hana normally (PID `9633`) and used `./scripts/run` to build, install and launch `/Users/beamsereeyothin/Applications/Hana.app`. The build is the uncommitted working tree on the baseline above. Strict signature verification and the built/installed executable SHA-256 comparison passed. The designated requirement is unchanged: identifier `com.beamseree.hana` with certificate leaf `5c1f81113eccdb4ae9b6d5c89aa22b045a29417b`.

- Running installed process at verification: PID `22739`.
- Installed executable SHA-256: `a0e48a8d4d39a9655846b11fe5d4e8886aa4cf6983f47f3b4dc04c8bf676d9b5`.
- The previous app bundle is retained in this session's temporary scratchpad, recorded in [install-result.json](install-result.json). It is not kept long-term.
- The native slot was acquired and released. No native tests ran during the install; no permission, shortcut or Spaces settings were changed.
- Raw evidence: [install.log](install.log), [install-result.json](install-result.json).

## Human acceptance

On 2026-10-26, using the installed build above, Beam reported: **"It switches now: a Word-paced answer below 90% switched with Agreeing verdicts set to 1."** Before this change, the same setup stayed at `agreement 1/2` without switching. This records Beam's interactive observation, separate from the automated checks above. Beam didn't give the exact probability, text or threshold.
