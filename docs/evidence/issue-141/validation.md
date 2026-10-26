# #141 calculator integration validation

2026-10-16, Asia/Bangkok. Integration branch: `codex/issue-141-integration`; main baseline: `d8fcf571c96b52b04b59c0cff6d5b98d9d2c1b12`.

## Final verification

The single resumed unlocked run of `xcrun swift test --no-parallel` passed **646 tests in 93 suites**, **134.513 seconds** test time / **135.558 seconds** process wall time, with actual **exit 0** and a complete successful summary. The 180-second deadline was not reached. **11 existing live-index tests were skipped by their environment gates.**

Tested head: `995b9c69580a8b25a60ba9e0b6a3cc7c72234127`; runnable source: `d54049ebef3f4674a27840fbfae0c12d3fed7e78`. Later commits contain evidence only. [Complete output](numeric-fixes/49-unlocked-final-full-tests.log), [direct process result](numeric-fixes/49-unlocked-final-full-test-result.json), [unlocked session state](numeric-fixes/50-unlocked-session-state.json) and [detailed numeric/harness validation](numeric-fixes/validation.md) preserve the source, timing and limits.

## Integration and review

Each ticket used its own implementer, branch and worktree, following implement/TDD at the public seams agreed in #141. Protected-head merges preceded explicit closure of tickets on the nondefault integration branch.

| Ticket | Merged PR | Result |
| --- | --- | --- |
| #142 Basic arithmetic | [#148](https://github.com/beamseree/hana/pull/148) | Closed |
| #143 Answerless states | [#150](https://github.com/beamseree/hana/pull/150) | Closed |
| #145 Automatic-switch blocking | [#151](https://github.com/beamseree/hana/pull/151) | Closed |
| #144 Full language | [#152](https://github.com/beamseree/hana/pull/152) | Closed |
| Numeric and native-host review corrections | [#153](https://github.com/beamseree/hana/pull/153) | Merged after final pass |

[Merge verification](pr153-merge.md) records the protected head, merge ancestry and byte-identical Sources, Tests, package manifests and scripts compared with the tested head. No additional test run is needed for the merge/evidence-only changes.

Final whole-integration reviews: [Standards](integration-standards-final.md) — **0 hard violations / 0 actionable smells**, with one optional fixture pasteboard duplication note; [Spec](integration-spec-final.md) — **0 unresolved findings**. The original multiplication exponent-wrap and false small-division findings, upper coefficient rebalancing, exact-range precision loss, extreme coefficient division and equivalent literal parsing are resolved. Independent numeric reviews covered 2,753 range/state cases, including 2,083 eligible display comparisons and 18 cancellation comparisons; a separate 77-case recheck and [320-case range oracle](exact-range-oracle-result.json) also reported zero mismatches. Calculator source/tests remain unchanged from the reviewed numeric revision `924766b`.

## Retained failures and native context

Earlier full/isolated runs without final summaries remain incomplete, including exit-0 attempts. [Read-only diagnosis](native-exit-diagnosis.md) and the actual suite exit trace identify the existing async-main/AppKit event-drain limitation. The affected failed/pending close tests now use the existing owned signed NSApplication child pattern. Original test names, parameters, actual close/sheet/copy/Store assertions and the joint pending-close predicate are preserved; no assertions are skipped or weakened.

The locked-session run was interrupted and is not acceptance evidence. Its native key-window failures and separate Store snapshot timeout are retained without attributing the latter to the lock. That snapshot test passed in isolation and the final complete suite passed on unchanged code. Child records also retain earlier failed/crashed development checks and their later passes.

## Handoff

The user resumed the native fixture slot for one bounded run. The slot was **released immediately after completion**; no further tests or apps were launched. No installation, real-provider request, permission/settings change, physical foreign-app focus observation or paste into a foreign application occurred.

[PR #149](https://github.com/beamseree/hana/pull/149) is ready for review and targets main; it is not merged into main by this run. Parent [#141](https://github.com/beamseree/hana/issues/141) and the separate human check [#146](https://github.com/beamseree/hana/issues/146) remain open until Beam's interactive acceptance evidence is recorded.
