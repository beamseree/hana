# Automatic switch debug footer

Implemented 2026-10-16 from Beam's approved footer plan and follow-up to keep it visible in Note and Task. Source is the local change on baseline `36734e6caf38dcfa4705bd1813ee54545e76f221`.

## Automated verification

- `xcrun swift build`: passed. See [build.log](build.log).
- Selected non-native regression run: **148 tests in 16 suites passed**, with no test skips. See [tests.log](tests.log).
- `git diff --check`: passed.
- Toolchain: Apple Swift 6.3.3, target `arm64-apple-macosx26.0`.
- Host: macOS 26.4.1 (`25E253`).
- The existing `MacInteractionTests.swift:452` sendable-closure warning remains non-fatal and outside this change.

Command used for the regression run:

```sh
xcrun swift test --no-parallel --filter 'AutomaticSwitchDebugTests|JevRequestActivityTests|JevSharedTransportTests|AutomaticSwitchTests|AutomaticSwitchWordPacedTests|AutomaticSwitchWordCacheTests|AutomaticSwitchDeletionTests|AutomaticSwitchWithdrawalTests|AutomaticSwitchReversalOptionsTests|AutomaticSwitchSubmissionTests|AutomaticSwitchReviewPolicyTests|AutomaticSwitchWakeUpTests|AutomaticSwitchSessionCountTests|AutomaticSwitchDiagnosticsTests|AutomaticSwitchWithdrawalDiagnosticsTests|ClassifierAdapterTests'
```

New deterministic coverage checks immediate-preference persistence independently of policy options, observation without firing, queue/current-prefix relevance, cache attribution, actual transport admission versus queued/cancelled work, earlier-invocation HTTP counts, observer cleanup, errors/timeouts/backoff, agreement counts, retained switch causes during Note/Task edits and late replies, raw request correlation for legacy strategies, and Foundation Models' local labeling. No live Jev calls are made.

## Native verification pending

Beam explicitly requested **Keep native tests pending** on 2026-10-16. No automated native window tests or agent-driven interactive visual/focus checks were performed for this change. The full suite was not run. Subsequent explicit requests authorized the installation and launch, followed by Beam's visual acceptance recorded below.

`AutomaticSwitchDebugInteractionTests` compiles with the test target. Its pending native checks cover the submenu toggle's immediate visibility and height change without changing policy/editor focus, retention through automatic switches into both Note and Task and subsequent edits, and reset on the next invocation. They can run when Beam hands over the native testing slot:

```sh
xcrun swift test --no-parallel --filter AutomaticSwitchDebugInteractionTests
```

Beam's overall visual acceptance is recorded below. Line truncation/tooltip readability, resizing with results and multiline capture or save notices, and keyboard focus were not separately reported as individual human checks. The automated policy/transport results do not establish those native outcomes.

## Installed build

At Beam's request on 2026-10-16, built the release bundle, normally quit the previous installed Hana, and used `./scripts/run` to install and launch `/Users/beamsereeyothin/Applications/Hana.app`. Both strict signature verification and the built/installed executable SHA-256 comparison passed. The persistent designated signing requirement remains identifier `com.beamseree.hana` with certificate leaf `5c1f81113eccdb4ae9b6d5c89aa22b045a29417b`.

- Running installed process at verification: PID `48682`.
- Installed executable SHA-256: `5e274f6378f1642df81a8a3829a41875c08e087f0a208d72267f232ce40a14b6`.
- Previous app bundle was retained in the temporary backup path recorded in [install-result.json](install-result.json).
- Native installation slot was acquired and released. Native tests remain pending; no permission, shortcut or Spaces settings were changed.
- Raw evidence: [release-build.log](release-build.log), [install.log](install.log), [install-result.json](install-result.json).

## Human acceptance

On 2026-10-16, after the installed build above was launched, Beam said **"looks good"** and requested that this change be pushed and a PR opened. This records overall visual acceptance of that installed artifact, separately from the passing non-native checks and the intentionally pending native test suite. No more specific focus, timing or per-state visual outcomes were supplied.
