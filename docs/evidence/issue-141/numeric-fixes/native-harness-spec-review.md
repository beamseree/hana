# Final Spec review: owned app-loop note-close fixture

Reviewed exact HEAD `d54049ebef3f4674a27840fbfae0c12d3fed7e78` against base `924766b4c3881d84e9223790212d1e4615330224` using `git diff 924766b4c3881d84e9223790212d1e4615330224...d54049ebef3f4674a27840fbfae0c12d3fed7e78`: two commits, four files, 157 insertions and 68 deletions. Uncommitted evidence was excluded from the code diff.

**Unresolved Spec findings: 0.** The prior P2 assertion-preservation finding is resolved. `Sources/Hana/NoteCloseValidation.swift:54-57` now polls the original simultaneous predicate, `arrivals.withLock { $0 } == 1 && platform.noteCloseIsHeld(note.id) && window.attachedSheet != nil`, before checking Saving status, available actions and regular activation. This preserves the original pending assertion at base `Tests/HanaTests/NoteSaveSafetyNativeTests.swift:201`, as required by the authorization to “preserve every original assertion” with “no weaker assertions.”

All original assertions remain across the four scenarios: native editor availability and `performClose`, the expected failed flush, attached close sheet, exact action choices, retained window identity, actual general-pasteboard bytes and window retention, retry/discard Store bytes, exact one paused arrival, Saving status, regular activation, final closure and pending Store close/reopen bytes. No skips, simulated/local-focus substitutions, normal product behavior changes or arithmetic changes were introduced. The added handler is opt-in, creates a newly marked disposable Collection and reuses the existing signed isolated NSApplication child pattern. Parent success still requires each scenario assertion marker, whole-validator success marker, exit 0 and no failure marker.

Read-only evidence inspection: `44-joint-pending-assertion-green.log` records all four child successes and a complete 24-test/two-suite summary in 7.570 seconds (seven native and 17 evaluator test functions). Full-suite verification remains a separate pending validation gate. No tests/apps were launched and no repository/GitHub state was changed by this review.

Spec count: 0 unresolved findings; previous P2 resolved.
