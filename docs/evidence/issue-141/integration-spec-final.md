Final whole-integration Spec review: pinned source `d54049ebef3f4674a27840fbfae0c12d3fed7e78` in `/Users/beamsereeyothin/.codex/worktrees/issue-141-calculator-numeric-fixes/hana`. Retains original integration review (`d8fcf571...38f4ab6`) against live #141–#145 and the cleared numeric review at `924766b4c3881d84e9223790212d1e4615330224`; adds the final narrow native-harness delta `924766b...d54049e`.

**0 unresolved Spec findings; worst issue: none.**

The original multiplication-wrap and false-small-division findings, upper coefficient rebalancing, and subsequent exact-range, normalization and literal gaps remain resolved. Independent public probes at unchanged numeric source `924766b` passed **77 cases with 0 mismatches**, covering those regressions, shared powers, exact upper/lower range checks, cancellation, long equivalent literals, locale formatting, grammar, percentages, functions and bounded recursion. Calculator source/tests are byte-identical at `d54049e`, so those results remain applicable without rerunning. The earlier whole-branch row/selection/Enter/gate/Debug assessment also remains valid.

The final harness preserves the original NoteSaveSafetyNativeTests assertions across failed-retry, failed-discard, pending-save and pending-discard:

- Real editor insertion and `window.performClose` still exercise native close/sheet dispatch; failed flush must produce the same storage error.
- Failed close retains the same window, exact action choices, actual general-pasteboard bytes and window retention after Copy; retry/discard still verifies exact Store bytes.
- Pending close waits for the original **joint predicate** `arrivals == 1 && noteCloseIsHeld && attachedSheet != nil` before Saving status, exact actions and regular activation. Save/discard still verifies closure and exact bytes after Store close/reopen.

Scenario selection maps each existing test parameter to its corresponding validated case. Child success requires its scenario assertion marker, whole-validator marker, exit 0 and absence of a failure marker. The existing owned child has a unique signed bundle, bounded launch/termination and cleanup. The opt-in handler creates a newly marked disposable Collection via `createFixtureRoot`; its early return precedes live Store/provider startup. Normal launch behavior is unchanged. No skipped or weakened assertion, simulated focus, material scope creep or other missing implementation found.

Evidence remains separate: `integration-spec-final-probe-result.json` records this reviewer's numeric run; native/full-suite validation belongs to the implementer's exclusive slot. This review launched no native tests/providers and changed no repository/GitHub state. #141/#146 remain open for the separate human trial.
