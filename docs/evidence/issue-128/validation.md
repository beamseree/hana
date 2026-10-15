# Issue #128 — Word-paced human trial

Status: trial preparation in progress. **The few-days human trial is not complete. #128, #115 and #120 remain open.**

## Existing candidate baseline

[pre-word-paced-counts.json](pre-word-paced-counts.json) contains a content-free aggregate captured before installing Word-paced. It groups the existing log by the complete option snapshot; combinations are not pooled. It records counters and latency samples without copying event rows or typed text. The existing executable SHA256 is included.

The current preferences were Jev, pipeline firing, threshold 0.70, Stay, one agreeing verdict, navigation suspension on, Enter saves, Escape returns to Search, reversing stops switching, no source wait, and late strong match stays. Full snapshot: [pre-trial-settings.json](pre-trial-settings.json). The trial changes only firing and the Word-paced reversal choice.

The earlier candidate did not record requests per session. Its latency can include cancelled/stale requests, which Word-paced excludes. The baseline spans several option combinations and is not a controlled same-input experiment. These limitations prevent inferring request savings or perceived latency from these aggregates.

## Trial handoff

The candidate source, signature, executable hash, settings and start boundary will be recorded after integrated verification and installation. A reset marker preserves earlier history in the content-free log.

## Pending human evidence

Beam uses the installed candidate normally for a few days. Record requests per session; switches, reversals/wrong switches, withdrawn, missed, errors and timeouts; backoff reasons; cache hits; and latency median/maximum. Keep each option combination separate.

Beam's observations on switch timing, last-word delay and Backspace behavior must remain separate from automated test results and logged counters. Record requested tuning and file any resulting follow-up issue. Post the completed summary on #115 and carry it into #107's go/no-go. No observation, tuning decision or trial outcome is invented here.
