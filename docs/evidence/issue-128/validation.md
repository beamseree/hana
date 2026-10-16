# Issue #128 — Word-paced human trial

Status: candidate installed and running; the native testing slot has been returned to Beam. **The few-days human trial is not complete. #128, #115 and #120 remain open.**

## Existing candidate baseline

[pre-word-paced-counts.json](pre-word-paced-counts.json) contains a content-free aggregate captured before installing Word-paced. It groups the existing log by the complete option snapshot; combinations are not pooled. It records counters and latency samples without copying event rows or typed text. The existing executable SHA256 is included.

The current preferences were Jev, pipeline firing, threshold 0.70, Stay, one agreeing verdict, navigation suspension on, Enter saves, Escape returns to Search, reversing stops switching, no source wait, and late strong match stays. Full snapshot: [pre-trial-settings.json](pre-trial-settings.json). The trial changes only firing and the Word-paced reversal choice.

The earlier candidate did not record requests per session. Its latency can include cancelled/stale requests, which Word-paced excludes. The baseline spans several option combinations and is not a controlled same-input experiment. These limitations prevent inferring request savings or perceived latency from these aggregates.

## Beam's pipeline observation

Beam reported in this chat on 2026-10-15: “its not bad, but i think this new version will be better”. This is an overall assessment of the pipeline and an expectation about Word-paced. No separate timing, last-word-delay or Backspace observation was supplied, and it does not evaluate the new candidate.

## Trial handoff

- Installed code: `b31ae3260922790218cbbf7f38b51a62c7573311`, after the final 491-test serial run. Current `origin/main` (`ced5e5f`) is already an ancestor; nothing is merged into `main`.
- Installation time: `2026-10-15T23:05:53.400435+07:00`. Full identity, settings before/after and reset boundary: [installation.json](installation.json).
- Built and installed executable SHA256: `5f87731b1a5addd15b8e6f860179195711fd6588fb9e8a6e6e24274389b91290`. Signature passed deep/strict verification; [signature output](installation-signature.log). Prior app is backed up in the local ignored `build/word-paced-candidate/previous-Hana.app`.
- Trial preferences: automatic switch On, Jev, Word-paced, Stay, threshold 0.70, Block that mode for this text. Enter saves, Escape returns to Search, one agreeing verdict, no source wait, navigation suspension and late-strong-match Stay are preserved. [Exact snapshot](trial-settings.json).
- A content-free `autoswitch.reset` row was appended and fsynced at `2026-10-15T23:05:53.400435+07:00` using the diagnostics row schema; older history was retained. The pre-Word-paced aggregate was refreshed through the orderly quit of the previous build. No typed rows were copied.
- Launch verified by process path/hash plus an AppKit event-loop sample and visible Task capture UI. No input text is retained in this record. UI automation’s initial windowless attach timed out; a later exact-path attach succeeded. This is automated observation, not Beam’s physical focus or latency assessment.
- Native testing slot released. Automated validation and review: [combined evidence](../issue-120/validation.md).

## Pending human evidence

Beam uses the installed candidate normally for a few days. Record requests per session; switches, reversals/wrong switches, withdrawn, missed, errors and timeouts; backoff reasons; cache hits; and latency median/maximum. Keep each option combination separate.

Beam's observations on switch timing, last-word delay and Backspace behavior must remain separate from automated test results and logged counters. Record requested tuning and file any resulting follow-up issue. Post the completed summary on #115 and carry it into #107's go/no-go. No observation, tuning decision or trial outcome is invented here.
