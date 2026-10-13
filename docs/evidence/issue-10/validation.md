# Issue #10 — integrated milestone assessment

2026-10-13. Scope: [#10](https://github.com/beamseree/hana/issues/10), Part of [#2](https://github.com/beamseree/hana/issues/2). **Acceptance remains incomplete; keep the PR draft.** Physical checks are in progress and physical shortcut-to-typing p95 is not measured. This report does not close #2 or claim completion of the full product (capture/persistence/organizer).

## Revision, identity and coordination

- User-approved comparison point: `20e67f87355d6c8d6c3d72adc8129b692e5be29d`. Closed blockers #4/#7/#8/#9 were verified through `./scripts/github ... --repo beamseree/hana`. Their merge commits and PR #17 are ancestors of this branch. Initial checkout `f51f6ee` lacked #9; branch `codex/issue-10-integrated-validation` was created from fetched `origin/main`.
- `origin` fetch/push already use `https://github.com/beamseree/hana.git`. Active AGENTS/CLAUDE/tracker docs and wrapper contain no directive to the former repository. Historical issue bodies/evidence were not rewritten. README/run instructions were stale about milestone scope and mandatory Full Disk Access; current guidance now distinguishes prior grants from required setup.
- Initial timing build: `696a992`. Final installed production source: **`ac4138a52750c97bcec74803fb08fce566ba4a28`**. Subsequent test/script/evidence/document edits do not alter installed app source.
- [Final installed identity](installed-build-final.txt): `~/Applications/Hana.app`, `com.beamseree.hana`, version 0.1.0/build 1. Executable SHA-256 `cc19d09a7d6d0a72cbc03ff402f3bc69dec98ef79df511493e75c13ffa46571b`; CDHash `8312e1bd0214499046b279a2d22ef0df8d3b271e`. Ad-hoc, no TeamIdentifier/entitlements/Sandbox/Hardened Runtime; strict verification passes. Local signing is not notarization/distribution approval.
- [Environment](environment.txt): macOS 26.4.1 (25E253), arm64; selected Xcode 26.6 (17F113), Swift 6.3.3, SDK 26.5; first-launch status passed; zero valid signing certificate identities. No toolchain reinstallation.
- Signed-app display inventory: built-in `(0,0) 1512×982`, scale 2, visible height 949; right external `(753,982) 2560×1440`, scale 1, visible height 1410; left external `(-1807,982) 2560×1440`, scale 1, visible height 1410. Geometry is in points. Actual invocation bounds can change with menu-bar placement.
- Hana reported Accessibility trust **false**, using foreign-origin pointer fallback. No permission/shortcut/global Spaces/display setting was changed. Prior #9 folder grants are historical evidence, not a fresh TCC inventory or proof of ad-hoc continuity. No new prompt/grant was documented in this run.
- Before installation: all other Hana chats were idle, #9 explicitly recorded native-slot release, and no Hana/prototype process was found. Only this chat installed the test build; benchmarks exited before subsequent launches. Physical testing uses a clean process without native UI automation, preserving #8's unresolved automation-session focus observation.

## Evidence types and reproduced defect

**D** primary API documentation; **A** deterministic tests; **L** opt-in live-index tests in the test process; **R** signed-app runtime/timing trace; **P** native sampling profile; **H** physical human observation; **N** untested. A build, screenshot, responder flag or Workspace acknowledgment is not physical focus/destination proof.

The initial broad synthetic `Hana` query reproduced input-actor stalls: the complete baseline run had 202/2,302 heartbeat samples with scheduling excess above 50 ms, maximum 363.15 ms. An independent 5-second Search regression failed at **349.44 ms** ([red](responsiveness-red.txt)). A second baseline run was profiled and interrupted; it is retained but excluded from the summary. The [profile excerpt](profile-before-excerpt.txt) sampled the main thread waiting in synchronous metadata IPC under `SpotlightSource.changed` → content-type `valueForAttribute`. This identifies app-attributable blocking work, although the heartbeat alone cannot attribute each delay.

Ranked hypotheses were per-item metadata fetches, large copy batches, and rendering/system contention. The smallest first change requests the type tree with the metadata query and reads its supplied name/type values. Batch size, source lifetime, generation fencing, ranking and layout stay unchanged. URL construction supplies a directory hint to avoid an implicit filesystem check on the input actor. The first attempt to use query values for paths returned nil on this OS; the file-presence regression caught it ([failed probe](query-value-missing-path.txt)), and the original item-path lookup was retained. No fallback-to-empty coverage claim was accepted.

The same opt-in Search regression then passed ([green](responsiveness-green.txt)), and the complete installed-app timing run had zero heartbeat excesses above 50 ms. No helper, extreme window level or suppressed animation was introduced. The original unreproduced top-left minimization observation and #8's earlier foreign-input failure remain observations with unknown causes; this fix is not attributed to either.

**D:** [Apple query-value documentation](https://developer.apple.com/documentation/foundation/nsmetadataquery/value(ofattribute:forresultat:)) says attributes must be requested in value-list/sort/group attributes. [Metadata query start](https://developer.apple.com/documentation/foundation/nsmetadataquery/start()) describes its queue/main-thread ownership. These were checked on 2026-10-13; they do not promise latency or focus. Existing [#9 API and permission evidence](../issue-9/validation.md) remains the source for discovery/opening capabilities.

## Automated checks and build/run instructions

- `xcrun swift build`: debug compile/typecheck passed; `./scripts/run --diagnostics --validate-performance` exercised release build, plist lint, bundle resources, ad-hoc signing, installation and Launch Services launch. [Final build/install output](final-build-install.txt).
- Search behavior: 20 executed tests pass, four indexed opt-in tests skipped in the focused default run (Swift Testing counts 24 total). Ranking, Unicode/literal matching, source failure/cancellation and bounded candidates are included. [Output](search-tests.txt).
- Mac Interaction: 18 session/selection/destination tests passed. [Output](mac-interaction-tests.txt). These are initial focused checks; final integrated suite is recorded below after physical testing.
- Opt-in live-index regression: three #7 cases passed on the fixed source (strong candidates after >2,000 broad false positives, usage beyond candidate cap, stable replacement snapshots). [Output](indexed-regression-tests.txt). The existing live-update test creates/removes one synthetic file and invokes `mdimport` for that file only; no global reindex/settings change.
- Existing punctuation test initially failed for broad `TextEdit` on both baseline and fixed source. Its assumption that a long fixture must always occupy a bounded result list is not a product guarantee. It now checks the exact system TextEdit app for that broad query, while exact filename, Thai/punctuation and multiword queries still require the fixture URL. [Baseline](punctuation-baseline.txt), [diagnostic](punctuation-diagnostic.txt), [green](punctuation-green.txt). This does not loosen exact-file or literal-punctuation requirements.
- Final full suite / signature recheck: pending physical shutdown.
- PR #17's `BarStyle.swift`, `SearchResultsView.swift`, `MacInteraction.swift` and logo have no diff from the review base. Rendering/focus still require H evidence; source identity alone is not a visual verdict.

## Performance: definitions, counts and limits

[Before raw data](performance-before.jsonl), [before summary](performance-before-summary.json), [after raw data](performance-after.jsonl), [after summary](performance-after-summary.json). Reproduce summaries with `scripts/validation/summarize-performance PATH`. Percentiles use nearest-rank, not interpolated p95.

Conditions: installed release/ad-hoc app, diagnostics on; existing indexed synthetic fixtures and conventional application roots; query `Hana`; zero working windows, foreign normal-app origin, pointer placement and three connected displays. OS/Spotlight caches were not flushed; **cold means process-cold or fresh catalog, not disk/index-cold**. Results are observed through Mac Interaction at 2 ms polling intervals and are not screen-paint timestamps. Each integrated query remains active for at least a second. Local-only samples then use a fresh Search/catalog with zero debounce and no file adapter. These conditions do not represent every app, query, full-screen Space or permission state.

One complete uninterrupted baseline run and one complete uninterrupted fixed run qualify: **1 process-cold + 30 warm integrated samples each; 1 fresh-catalog + 30 warm local samples each**. The second baseline run was profiled/interrupted. A later fixed run overlapped an opt-in test ([retained separately](performance-overlapping-test.jsonl)); another was interrupted by outside-click at sample 8. Neither contributes to accepted figures. The summary excludes an ended run unless all 31 integrated contexts and all 31 local samples succeeded; an end marker alone is not completion.

| Measurement | Before warm p95 / max | Fixed warm p95 / max | Fixed cold sample | Meaning / target assessment |
| --- | --- | --- | --- | --- |
| `presentBar()` call | 11.44 / 14.59 ms | 15.52 / 18.19 ms | 23.80 ms | Synchronous call only (AX false), not physical shortcut-to-typing. **Physical p95 <100 ms remains unmeasured** |
| Programmatic native `insertText` call | 4.17 / 4.92 ms | 4.59 / 4.82 ms | 8.35 ms | Editor insertion plus synchronous query work; no hardware event/paint latency |
| First application result observed | 309.19 / 309.47 ms | 183.06 / 185.94 ms | 194.55 ms | Includes nominal 100 ms debounce, scheduling, merge/rendering and polling. Subtracting 100 ms is only an estimate, not a measured post-debounce boundary |
| Local-only Search service | 29.96 / 31.56 ms | 28.87 / 30.18 ms | 846.52 ms fresh catalog | Zero-debounce cached Search delivery/ranking, no files/UI. Warm service cost is below 100 ms; does not alone prove full UI post-debounce budget |
| First non-application result observed | 1053.50 / 1055.78 ms | 251.88 / 263.89 ms | 217.45 ms | Includes production debounce/rendering/polling; observed warm sample set satisfies preferred <300 ms first-file goal |
| 5 ms heartbeat scheduling excess | 55.47 / 363.15 ms | 2.26 / 21.77 ms | Included in run | Before n=2,302, 202 >50 ms; after n=5,845, zero >50 ms. Includes OS contention; proxy, not physical typing-stall proof |

Miss investigation: main-thread metadata IPC explains the reproduced broad-query stalls; the fix and rerun support that cause. Fresh local catalog initialization still takes 846.52 ms in the fixed sample (baseline 929.22 ms), while cached delivery is fast. Catalog enumeration already runs detached; its cold delay is not an input freeze or a warmed guarantee. First-process results can use catalog refresh work begun at app startup, unlike the separate fresh-catalog sample. Remaining physical timing and broader cold conditions are unmeasured; no guarantee is claimed.

## Native lifecycle, editing and destination matrix

The [physical procedure](physical-checks.md) defines the required cases. The final build was relaunched with only `--diagnostics`; physical answers and trace corroboration will be entered here. Prior #4/#8 passes are not promoted to current-build passes.

| Case | Current evidence / status |
| --- | --- |
| Normal + full-screen origin × zero/open-three/minimized-three; immediate typing/Escape, no unwanted invocation Space transition or unrelated raising | **H pass**: Beam answered “All six pass” for the explicit six-combination procedure. Grouped confirmation covers typing, Escape return, stable input, no invocation jump/unrelated raising. R corroboration is separate in physical-runtime.jsonl. |
| Dock/Command-Tab, Main-only Dock reopening, single/bulk minimization, close/reopen transitions | H pending |
| Reinvoke retains query, rapid fresh reopening, outside-click typing, working-window destination from full screen, menu/hotkey after last close | H pending; A checks narrower session fences |
| English/Thai physical editing, selection, literal paste, undo/redo, native context menu | H pending; existing A editor preservation does not prove physical input |
| Stable resizing, built-in/both external placement, owned-window precedence | H pending; geometry A separate |
| Exact application/file/folder destination and typing focus from full-screen origin | H pending; acknowledgment is not a pass |
| Selection during late file batches; failed opening retains context; successful opening never restores origin | H pending; deterministic A checks controlled batches/open outcomes |
| Current PR #17 bezel/card/shadow/placeholder appearance | H pending; style source unchanged |

## Coverage and permission consolidation

Use [#9's matrix](../issue-9/validation.md) as prior signed-app evidence, including grants, duplicate names, renamed/deleted destinations, distinct installations, protected Mail EPERM, uncommon-extension failure and context preservation. It is not rerun wholesale: the #10 metadata-fetch change affects discovery value retrieval; indexed literal/stress/update cases were rerun and physical app/file/folder selection is requested. Opening/error classification and permissions code are unchanged. Genuine stale-URL failures and Mail EPERM remain prior R evidence; deterministic denied/missing/open-race cases remain A evidence.

Unavailable/deferred: physical sub-100-ms p95 apparatus; candidate IME; successful trusted foreign AX placement (Hana untrusted); display hot-plug; Stage Manager; sleep/lock; indexed external storage; known cloud-only placeholder; confirmed pre-existing Spotlight Privacy exclusion; denied document-opening/revocation under a changed TCC state. No settings/mounts/evictions/grants were manufactured. Slow/empty metadata is not labeled permission denial or absence of files. No Spotlight-parity claim.

## Parent #2 acceptance

Reproducible integrated source/build/signature and deterministic behavior are supported; the reproduced main-actor metadata stall is fixed with red/green and installed-runtime evidence. Preferred warm first-file timing passes this bounded sample; physical invocation latency and physical typing-stall guarantees are not established. Current-build lifecycle, editing and destination observations remain pending. **Parent milestone acceptance is incomplete; PR stays draft, #2 stays open.** ADR 0005 stays proposed and retains both historical unexplained observations. No capture/persistence/organizer expansion.

## Review and shutdown

Two-axis review, final full-suite output, exact final revision and native-slot/shortcut release will be recorded after physical testing.
