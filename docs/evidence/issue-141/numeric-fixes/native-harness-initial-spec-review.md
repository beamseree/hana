# Spec review: owned app-loop note-close fixture

Reviewed exact HEAD `6a148ed886ce88d7bcf01484b228228b302c99e3` against base `924766b4c3881d84e9223790212d1e4615330224` using `git diff 924766b4c3881d84e9223790212d1e4615330224...6a148ed886ce88d7bcf01484b228228b302c99e3`: one commit, four files, 152 insertions and 68 deletions. Uncommitted evidence was excluded from the code diff.

**1 finding — [P2] Preserve the pending-close conjunction.** Authorization requires “preserve every original assertion” and “no weaker assertions.” The original pending test at base `Tests/HanaTests/NoteSaveSafetyNativeTests.swift:201` asserts one eventual predicate: `gate.arrivals == 1 && interaction.noteCloseIsHeld(note.id) && window.attachedSheet != nil`. New `Sources/Hana/NoteCloseValidation.swift:53-58` checks the held close/sheet first, then checks only arrivals in a separate awaited poll. It can observe the sheet before the commit pauses and later pass after that sheet disappears; the original required simultaneous observation. Restore the original conjunction in the pending branch, retaining the exact arrival count.

All other original checks are present across failed-retry, failed-discard, pending-save and pending-discard: actual native `performClose`, editor availability, expected flush error, close actions, retained window identity, exact general-pasteboard text and window retention, retry/discard Store bodies, Saving status, regular activation, final window closure and pending Store close/reopen bytes. The existing signed child fixture requires both scenario assertion and whole-validator success markers, exit 0 and no failure marker. The handler is opt-in and uses a newly marked disposable Collection; no normal product path or arithmetic implementation changed.

Read-only evidence inspection: log `43-harness-and-evaluator.log` records four child successes and a complete 24-test/two-suite summary (seven native and 17 evaluator test functions). This does not supply the pending full-suite result. No tests/apps were launched and no repository/GitHub state was changed by this review.

Spec count: 1 finding, worst P2.
