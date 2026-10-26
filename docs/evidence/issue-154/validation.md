# Issue #154 — Application catalog refreshes on filesystem changes

Implemented on `claude/issue-154-93af1d`, based on `d8fcf57`. macOS 26.4.1 (`25E253`), Xcode 26.6 (`17F113`), Apple Swift 6.3.3, arm64, on AC power.

The catalog no longer polls. It enumerates at launch, then rescans only when a file-level FSEvents stream over the conventional roots reports a change that can alter the enumeration. Rescans are at least 2 s apart, and a rescan that finds the same results publishes nothing. See the [technical design](../../technical-design.md#application-catalog-refresh--issue-154).

## Idle CPU before

Installed build `bef089d101d33b293a90f19bfb4a4f71a6bc2a802fb4a6dae69791538997449a` (main at `d8fcf57`'s era), PID 9633, Search bar closed, no application changes. See [before-identity.txt](before-identity.txt) and [before-idle-cpu.txt](before-idle-cpu.txt).

- At the start of measurement the process had used 12:53 of CPU in 60:36 of running, about 21%.
- Over the five-minute window (02:25:46–02:31:00 UTC, 314 s): 59.6 s of CPU, **19.0% average**. `top` sampled every 5 s, mean 18.0% (63 samples).
- A 10 s stack sample ([excerpt](before-sample-excerpt.txt)) put 2,065 of 8,296 samples on the utility cooperative thread in `ApplicationCatalog.refreshIfChanged()`. Of those, 1,949 were in `stamp(_:)` → `FileManager.attributesOfItem`. The busiest non-idle leaf frames were `getattrlist`, `stat`, `lstat` and `listxattr`.

## Idle CPU after

**Pending.** It needs the installed app replaced with this build. Beam approved replacing PID 9633 for this measurement. Before it was taken, another build (`a0e48a8d…`, installed 09:36:42 local time by something outside this session) replaced it. That build also polls: 10:25 of CPU in 53:34, about 19%. The after-measurement and stack sample wait for Beam's go-ahead to replace that installation.

## Acceptance mapping

| Acceptance criterion | Evidence | State |
| --- | --- | --- |
| No periodic catalog work while idle; under 1% CPU over five minutes; no catalog activity in a stack sample | `ApplicationCatalogTests.idleCatalogDoesNoFilesystemWorkAfterLaunch`: one pass, then none for 3 s ([red](idle-red.txt) against the polling catalog: 3 passes) | Automated pass; installed-build CPU and sample pending |
| Not listed under "Using Significant Energy" | — | Pending Beam's observation |
| Install, remove and rename in a root or an organizational folder reach an open query within seconds; existing coverage passes; new rename and nested-folder coverage | `SearchTests.catalogRefreshesAnActiveQueryAfterInstallationAndRemoval` (existing), `…AfterRename`, `…ForAnOrganizationalFolder` | Automated pass ([focused](focused-green.txt)); see delivery lag below |
| Info.plist display-name change updates the result | `SearchTests.catalogRefreshesAnActiveQueryAfterAnInfoPlistNameChange` | Automated pass |
| A root missing at launch becomes searchable when created | `SearchTests.catalogFindsApplicationsInARootCreatedAfterLaunch` (canonical path, like `~/Applications`; install 1 s after the root appears) | Automated pass |
| A burst rescans a bounded number of times | `rewritingFilesInsideABundleCausesNoRescan` (5 waves of 40 writes, 0.7 s apart: at most 2 rescans; [red](bundle-burst-red.txt): 12), `aBurstOfChangesCoalescesIntoFewRescans` (300 folders: at most 3), `aLongInstallationRescansAtABoundedRate` (a folder every 0.25 s for 4 s: at most 4; [red](long-burst-red.txt): 7 and 9) | Automated pass |
| Dropped events cause a full rescan | `MustScanSubDirs`, user/kernel drops, wrapped IDs, root changes and mounts always signal; every rescan is full | Code only: Beam chose not to add an injected-event seam, and a real disk cannot be made to drop events |
| Before and after idle CPU recorded here | Before above | After pending |

Test seams agreed with Beam: `Search(roots:)` over real temporary directories, and `ApplicationCatalog` snapshots plus an internal `scans` count (like `ResultIcons.cachedCount`) with real FSEvents.

## Red/green record

- Idle: [red](idle-red.txt) with the polling catalog, green with FSEvents.
- Bundle internals: [red](bundle-burst-red.txt) (12 rescans) before the relevance filter. That log predates the settled-fixture rework, so it shows the earlier `<= 3` assertion.
- Long installation: [red](long-burst-red.txt) (7, 9 rescans) before the 2 s minimum interval. An earlier run had passed only because FSEvents delivery stalled and flushed the whole burst at once.
- Existing installation-and-removal test: [red](install-removal-red.txt) when the fixture root's own late creation report published an identical empty snapshot. Fixed by not publishing unchanged snapshots.
- Rename, organizational folder, Info.plist and late-root tests passed when first written ([search-coverage.txt](search-coverage.txt), [missing-root-green.txt](missing-root-green.txt)): they pin existing behavior.

These iteration logs come from uncommitted development stages. [focused-green.txt](focused-green.txt) is the final source's focused run; eight consecutive focused runs of both suites together passed.

## FSEvents observations on this Mac

Separate scratch programs, not shipped:

- **Missing roots.** A root absent when the stream starts is reported once created, and so are changes inside it, because FSEvents matches watched paths as strings. Beneath a symlinked ancestor (temporary directories under `/var` → `/private/var`), every change is reported as root-changed instead, which also rescans. Two early runs showed lost or late events after a late root appeared; repeated later runs, and every run of the late-root test, did not reproduce that.
- **Sticky flags.** Item flags accumulate: an xattr change on a just-created bundle still carries `ItemCreated`. Fixtures created just before a stream starts are reported after it starts, so the catalog tests let them settle first.
- **No last-used xattrs.** `/Applications` bundles here carry no `com.apple.lastuseddate#PS`, so launching apps is not expected to write the bundles. Xattr-only changes still rescan (harmlessly, and unpublished when nothing changes).
- **Delivery lag.** On a quiet system, deliveries took 0.01–2.9 s and the install/removal test 1.2–1.4 s. During this session `fseventsd` ran at about 98% CPU with no tests running (119 h of CPU in 171 days of uptime). While full suites ran, an independent probe process saw 18 of 21 deliveries take over 2 s, a maximum of 16.9 s and two 40 s timeouts. In a baseline run of `d8fcf57`'s suite, which creates no catalog streams, the probe also saw 15 s delays and timeouts. Every client in a process was delayed and flushed together. The lag is the system's, not this change's, but catalog updates wait on it, where the old poll noticed changes within about 2 s.

## Full suite

`xcrun swift test --no-parallel`, holding `/tmp/hana-spec-88-native-lock` (released after each run). Last run on the final source: [full-suite.txt](full-suite.txt), 621 tests in 90 suites, 5 issues in 3 tests:

- `MainNoteOrganizationTests.noteMenusActOnSelectionAndHaveKeyboardEquivalents`: a native child-fixture failure at menu steps. It fails 6 of 8 runs on unmodified `d8fcf57` ([native-flake-baseline.txt](native-flake-baseline.txt)) and 1 of 4 here ([native-rerun.txt](native-rerun.txt)).
- `TaskWorkspaceOrderTests.moveUpDownMenusRouteOrderingAndYieldToInlineEditing`: a native menu-routing assertion, unrelated to the catalog, not reproduced in the other runs.
- `SearchTests.catalogRefreshesAnActiveQueryAfterInstallationAndRemoval`: exceeded the 60 s limit with no delivery, during the `fseventsd` lag above.

Five full runs on this branch: one before the review fixes, the run above, and three with temporary diagnostics. One passed all 621 tests. The installation-and-removal test passed in three (10.6–30.1 s) and timed out in two. The other failures were native flakes: the two above, `MacInteractionTests.typingKeepsHeightUntilBothSourcesFinishAndClearingCollapses` once (it passed twice when rerun alone) and `AutomaticSwitchInteractionTests` once. Unmodified `d8fcf57` passed 613 tests in 103 s, its installation-and-removal test taking 2.2 s by polling. Instrumentation showed no catalog leaks (107 created, 106 released, at most 7 alive) and no failed stream creation or start.

## Limitations

- Dropped-history handling has no automated test (see above).
- A conventional root created after launch *as a symlink* is reported only as a symlink event and ignored until the next launch or another reported change.
- Localized names from `InfoPlist.strings` inside a bundle do not trigger a rescan; the issue allows this, and the old poll behaved the same.
- If `FSEventStreamCreate` or `FSEventStreamStart` fails, the catalog keeps its launch enumeration and does not refresh.
- No install, rename or removal was performed in the real conventional roots. Physical Search checks there and the battery-menu observation remain with Beam.
