# Issue #5 — application Search validation

Parent: [#2](https://github.com/beamseree/hana-searchbar/issues/2). Scope: cached application search and exact-installation launching only. File search, capture, persistence and organizer remain absent. The isolated prototype is untouched.

## Base and environment

- Started clean on current `origin/main` `c7abb2e8dfe12eb469b66db29b3dd89a136aa8c0`; blocker #3 closed. Main includes merged #4 / PR #12. Branch: `codex/issue-5-app-search`.
- macOS 26.4.1 (25E253), arm64; Xcode 26.6 (17F113), Swift 6.3.3, macOS SDK 26.5.
- Installed identity: `com.beamseree.hana`, `~/Applications/Hana.app`. Ad-hoc signed, no entitlements, no permission or Spaces changes. This does not establish distribution readiness or TCC continuity.

## Behavior and coverage

Search accepts a request generation and yields immutable bounded batches with catalog status. Empty/whitespace queries do not subscribe to a source. Matching uses canonically normalized, case-folded comparison values, preserving Thai marks and the native typed buffer. All whitespace-separated tokens must occur literally in a name. Name tiers precede session-only successful-use count/recency, then normalized name and exact path. Catalog name and installation filename remain searchable. At most 20 results are delivered.

Catalog roots: `/Applications`, `/System/Applications`, `/System/Library/CoreServices/Applications`, `~/Applications`. Organizational directories are traversed; hidden entries, symlinked directories and app/package internals are not. Discovery outside those roots and Spotlight supplementation belong to subsequent source integration, not this issue. Identity uses the standardized installation URL fallback; distinct installation paths remain distinct. A moved installation invalidates its old selection.

The catalog scans at launch off the main actor. Once per second it checks only previously discovered directory/bundle-metadata modification times, plus root parents to detect newly created roots. Changed stamps trigger a fresh bounded-root scan. It does not scan on each keystroke or crawl the disk. Missing optional roots are empty; observed read errors produce an unavailable-source status while retaining results from readable roots. The initial refresh test exposed cached URL resource values; direct filesystem attributes fixed refresh detection.

Selection is held by identity across batches. Once a selected identity vanishes, no adjacent result is selected automatically. Return captures the currently visible destination synchronously. The native adapter revalidates the bundle/executable and calls `NSWorkspace.openApplication(at:configuration:)` with running-application substitution disabled. Acknowledgment closes that invocation without origin activation; reported failure preserves the query and gives recovery guidance. The native request uses `activates = false`; its acknowledgment carries the exact returned running instance. Only a current invocation and query can synchronously dismiss and request activation of that instance. Stale acknowledgment does neither. Ordinary app/Space changes still dismiss normally; no broad notification suppression is retained. Native launch requests already issued cannot be recalled, and a third-party application could independently activate itself despite a background launch request.

## Automated evidence

TDD red → green slices were observed for initial matching interface, deduplication before limiting, multiword literal matching, real directory traversal through Search, usage ordering within name tiers, filename aliases, and synchronous selected-destination capture through Mac Interaction. Existing/reinforced tests cover cancellation, empty queries, installation/removal refresh, English/Thai and canonical normalization, selected-identity disappearance, stale batches, controlled launch failure and obsolete acknowledgment.

Run focused checks with `xcrun swift test --filter SearchTests` and `xcrun swift test --filter ApplicationInteractionTests`; complete suite/build/signature results are recorded below after final validation. Controlled filesystem and workspace failures are not proof of macOS permission denial. AppKit session tests cannot establish foreign keyboard delivery.

## Runtime trace versus physical observation

- **Human observation, first integration:** Beam confirmed invoke/query/navigation/launch works from a normal app.
- **Runtime trace:** the normal-origin selection was followed by `launch.acknowledged` with TextEdit workspace-frontmost and `dismiss.destination`. This is acknowledgment/frontmost evidence; Beam supplies the destination/focus observation.
- **Human observation, failure:** over native full-screen Notes, typing went to Notes instead of Hana, even after clicking Hana. The trace reported a key panel and accepted editor responder with no text changes; these state flags did not establish keyboard delivery.
- **Controlled comparison A:** disabling only the result hosting view, restarting and retaining Main made physical full-screen input work. Beam confirmed text entered Hana; the trace includes text changes, batches and Escape. Comparison B restores hosting to separate a hosting issue from restart/launch-lifecycle effects.

## Reproduction procedures

Physical focus loop: `scripts/validation/full-screen-input-loop`. The initial recorded verdict was `FULL_SCREEN_INPUT=fail`, `AFTER_CLICK=fail`. Values were transcribed from Beam's chat response, not automated keyboard assertions.

`./scripts/validation/install-app-search-fixtures` creates two ad-hoc-signed `Hana Search Fixture.app` installations under `~/Applications/Hana Search Validation/One` and `Two`, with the same name and bundle identifier. Search their shared name, choose each path and verify the window's installation label and immediate typing. Keep One running while launching Two to verify no running-instance substitution. `Hana Broken Fixture` has no executable: Return must show recovery guidance and retain the query. The fixtures save nothing and the installer refuses to overwrite an existing fixture folder. Remove that named folder after quitting the disposable fixtures when validation is finished.

Pending acceptance items and final review results must remain explicit; no undocumented pass is implied by this record.

## Follow-up comparison

Beam confirmed comparison B (hosting restored) accepts physical typing over full-screen Notes both before and after a TextEdit launch. Restart is a confounding factor: no hosting defect or root cause has been established, and no speculative focus workaround is retained. The diagnostic switch was removed; the reproduction loop remains. Final integrated repetition follows the completed automated tests so AppKit test processes do not overlap physical acceptance.

The complete suite initially exposed a fixed-delay assumption in the controlled source fixture. The fixture now explicitly waits for the replacement subscription; it no longer relies on ten milliseconds being enough under concurrent suite load.


## Integrated physical acceptance (2026-10-13, 13:43–13:46 ICT)

Beam answered “everything seems to work as intended” to these three explicitly enumerated groups. This is broad human confirmation, not separate instrumented measurements of every subcase:

1. Full-screen Notes: three invoke/type/Escape repetitions, TextEdit launch and return/reinvoke, and another repetition with Hana Main/Mock windows minimized; intended typing destination and no unwanted Space jump.
2. Two same-name/same-bundle-ID fixtures: select installation One by its path and type without a click; leave One running, select installation Two, observe “Installation: Two” and immediate typing.
3. Broken fixture: retain query with recovery guidance. English/Thai typing, selection, paste, undo during expansion, then empty input with no results.

The trace independently corroborates full-screen-origin search/text/selection, native acknowledgments, and a failed launch retaining nine UTF-16 units. Bundle-ID traces cannot distinguish the two fixtures; their exact-installation result comes from the requested visible label and Beam's response. A native acknowledgment while Notes was still workspace-frontmost demonstrates why acknowledgment alone is not focus proof.

## Initial timings (not final performance acceptance)

Instrumentation enabled, three displays reported, same running process/catalog, ordinary manual typing. Placement samples span the primary display and a display with negative horizontal coordinates. In the 06:42:46Z build run: 16 synchronous presentation samples, 5.26 / 7.49 / 33.08 ms min/median/max. The first presentation after this process launch was 33.08 ms (one sample); this is not an OS-cold benchmark. Sixty nonempty-query batch samples were 106.19 / 119.15 / 139.65 ms min/median/max including the nominal 100 ms debounce, ranking, result delivery and rendering/diagnostic work. Catalog initialization had already occurred before these manual queries.

These samples do not measure physical hotkey-to-typing readiness, cold filesystem cache cost, a statistically reliable p95, or worst input stalls. No final engineering target is claimed. The trace shows placement on multiple displays including negative coordinates, but no isolated physical multi-display acceptance or disconnect check was requested. Permission revocation and candidate-IME cases remain untested; IME is explicitly deferred by the parent. File permissions/Spotlight coverage belong to subsequent tickets.

## Review correction

Independent Standards review found zero actionable findings. Spec review found that guarding only the open completion did not prevent an already-issued activation from producing late workspace notifications. A controlled Space-notification test reproduced a cleared new invocation/query. The first proposed outstanding-operation map was rejected because it still depended on notification ordering and suppressed unrelated user Space changes.

Final correction: background native opening, followed by exact-instance activation only after both invocation and query-generation guards, with no await between guard and effects. Boundary tests now assert that obsolete completion and changed-query completion never invoke activation, current opening targets the selected installation, and ordinary Space changes still dismiss. `launch.acknowledged`, `launch.activation-request` and physical destination focus are separate evidence. The original intermittent full-screen typing report has no established cause and is not attributed to this race.

Final automated suite: 18 tests passed, including existing shell lifecycle tests. See [test output](tests.txt). The final activation path receives a focused physical recheck after installation below.


## Build identity and primary API checks

Final code revision `aed41f9`; release build, plist lint and strict ad-hoc signature verification passed. Installed CDHash: `8d405c2c7b6256fe1b76dc4e1f76ad22bda04627`. No TeamIdentifier or entitlements. The app still uses its original bundle identifier and installation path; no privacy/global settings changed.

Apple's [native application-opening documentation](https://developer.apple.com/documentation/appkit/nsworkspace/openapplication(at:configuration:completionhandler:)) and selected SDK `NSWorkspace.h` were rechecked. The SDK explicitly documents disabling `allowsRunningApplicationSubstitution` for choosing an installation; `activates` controls foreground activation. The returned running instance is used for the guarded activation request. These are documented capabilities, separate from the observations above.

| #5 acceptance | Evidence |
| --- | --- |
| Cached conventional-root catalog and refresh | Real temporary-directory tests through Search, installation/removal refresh, runtime fixture discovery |
| Bounded typed results and distinct paths; empty input | Search tests, 20-row cap, physical same-name fixtures and clear-input check |
| Deterministic name tiers, literal English/Thai, retained editor | Search tests, native editor unchanged during resizing, Beam's input/selection/paste/undo observation |
| Selection identity, obsolete queries and vanished selection | Controlled batches, captured destination, explicit invalidation and no-neighbor-opening tests |
| Revalidation, native exact open, failure and obsolete completion | Native missing-path test, controlled failure/delay tests, real broken fixture, guarded exact-instance activation |
| Automated seam coverage | 18 passing tests; [output](tests.txt), [review](review.md) |
| Real invoke/query/select/launch, focus, failures and initial timings | Grouped human observations, [runtime trace](runtime.jsonl), measurements above; revised handoff recheck below |
