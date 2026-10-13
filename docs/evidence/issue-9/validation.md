# Issue #9 — signed-app coverage and permissions

2026-10-13, macOS 26.4.1 (25E253), Apple Silicon. Scope: [#9](https://github.com/beamseree/hana/issues/9), under parent #2. This is bounded coverage evidence, not Spotlight parity or completion of the parent milestone.

## Identity and conditions

- Base/review point: `f51f6eeced6abe1fd0b52b2c6b70806e978668c4` (merged PR #17). Its ancestry includes merged #7/PR #16 and #8/PR #15. #6, #7 and #8 were closed when checked.
- Initial installed source: `7fae3ebca57ec1dd10ded1a9ebc19997d471df39`; [identity](installed-build.txt). Final tested source contents: `12572b9deb792a34f7b2ca4f67362b7ee78c7a5f`, committed after building those same contents. Later commits contain evidence/documentation only.
- Final executable SHA-256: `13eaea4b6d61a81a1101fc4b4372ec1698159a32fdbb3260aa764480bc7f78fe`; CDHash: `8245854a902f1536570c6262d6729bc5a1a71b69`. [Signature record](installed-build-final.txt).
- Installed at `~/Applications/Hana.app`; bundle `com.beamseree.hana`, version `0.1.0` / build `1`. Ad-hoc signature, no TeamIdentifier, no entitlements, no App Sandbox or Hardened Runtime. Strict verification passed. Xcode 26.6 (17F113), Swift 6.3.3, SDK 26.5. These are local signing facts, not notarization or distribution approval.
- Other implementation chats were idle; #7/#8 had recorded slot release; no Hana/prototype/build process was running at entry. Only this chat installed Hana. The final normal-mode process was quit by Beam at 16:58:42 ICT; shutdown is in [physical-runtime.jsonl](physical-runtime.jsonl), and `pgrep -x Hana` returned no process before the final suite.
- **Permission context changed during testing:** Beam reported macOS permission prompts during the automated native run and personally allowed every prompt. He recalled Desktop/Documents/Downloads but did not remember the exact prompt sequence. No precise per-folder TCC grant inventory was collected. Successful coverage below is **after these user-approved grants**, not evidence of prompt-free access. The agent did not accept prompts, alter settings, add entitlements, or request Full Disk Access/folder-selection setup. Ad-hoc rebuilds may affect permission continuity.
- Hana reported Accessibility trust false. Only the startup volume was mounted. No cloud-only synthetic placeholder or confirmed existing Spotlight Privacy exclusion was identified. No settings, exclusions, downloads or new mounts were created to manufacture these cases.

## Evidence key and method

**D** = documented API capability; **A** = deterministic automated behavior test; **R** = trace from the installed signed app; **U** = native accessibility observation of a destination window; **H** = Beam's physical observation; **N** = untested/unavailable. Request acknowledgment and activation-request acceptance are not document or typing-focus proof.

`scripts/validation/install-coverage-fixtures` creates only synthetic destinations under `~/Desktop/Hana9 Coverage`, `~/Documents/Hana9 Coverage`, `~/Downloads/Hana9 Coverage` and the existing OS temporary directory. It refuses existing roots. The two pre-existing synthetic apps from `install-app-search-fixtures` were reused. They have the same bundle ID/name but distinct One/Two installation URLs.

`./scripts/run --diagnostics --validate-coverage` drives production Search and Mac Interaction in Hana. Selection uses the exact known URL, followed by the ordinary opening operation. All query/result matching comes from the running app, never terminal counts. The final runner also reads resource attributes/visibility and `NSMetadataItem` filename availability for only the known fixtures; these are separately marked **resource** probes, not discovery. They run before searches and can affect permission prompts/cache conditions; this is not a cold/unprimed benchmark. No metadata import/reindex command was used. Logs contain case IDs, numeric error codes, state/counts and text lengths, never arbitrary query contents, filenames or localized error descriptions.

The initial run had empty results and user interference (typing changed the Desktop query; an outside click interrupted Downloads). It is not valid negative coverage for those cases. A second run was aborted on interference. Keep [initial-runtime.jsonl](initial-runtime.jsonl) and [interrupted-runtime.jsonl](interrupted-runtime.jsonl) as history, not passes. The clean coverage run at 16:50:22–16:51:22 ICT completed: [coverage-runtime.jsonl](coverage-runtime.jsonl). Its negative checks waited four seconds, or twelve for an expected destination; completed source batches are corroborating observations, not proof of index completeness. Initial gaps cannot independently diagnose permissions, absence or index latency. Later grants and successful discovery do not isolate the earlier cause.

## Coverage matrix

Unless stated otherwise, the selected/attempted destination is the exact synthetic URL named in the row. `D`, `M`, `L` below mean the Desktop, Documents, Downloads fixture roots. All **R** rows refer to the clean coverage run; physical follow-up uses the same installed binary with only `--diagnostics` and normal sources.

| Case / expected inclusion | Actual discovery | Selected destination / opening attempt | Acknowledgment | Observed destination behavior | Limits / evidence |
| --- | --- | --- | --- | --- | --- |
| D/Hana9 Desktop.txt — eligible | Found | Exact D file; attempted | Accepted | Beam saw `HANA9-DESKTOP`, typed without clicking, undid typing | R + H; after grants |
| M/Hana9 Documents.txt — eligible | Found | Exact M file; attempted | Accepted | No separate document-content observation | R; display/focus not claimed |
| L/Hana9 Downloads.txt — eligible | Found | Exact L file; attempted | Accepted | No separate document-content observation | R; display/focus not claimed |
| D/Hana9 Duplicate.txt — eligible distinct URL | Found | Exact D duplicate; attempted | Accepted | No separate marker observation | R; name shared with M/L |
| M/Hana9 Duplicate.txt — eligible distinct URL | Found | Exact M duplicate; attempted | Accepted | No separate marker observation | R; name shared with D/L |
| L/Hana9 Duplicate.txt — eligible distinct URL | Missing in clean automated run despite readable attributes/eligible visibility; metadata name unavailable then. Later Beam saw all three results | Beam selected L duplicate and pressed Return | Physical trace at 16:57:21 records request/acknowledgment | Beam confirmed `HANA9-DUPLICATE-DOWNLOADS` | R + H; initial cause unproven, no reindex/grant change made for follow-up |
| D/Hana9 Desktop Folder — eligible folder | Found | Exact folder; attempted | Accepted | No isolated Finder observation | R; no narrow extension whitelist |
| M/Hana9 Documents Folder — eligible folder | Found | Exact folder; automated and physical attempts | Accepted | From a full-screen origin, Beam saw the exact Finder folder without return to origin | R + H; intentional destination transition |
| L/Hana9 Downloads Folder — eligible folder | Found | Exact folder; attempted | Accepted | No isolated Finder observation | R |
| M/Hana9 Ordinary.uncommon — eligible ordinary file | Found | Exact file; attempted | Rejected: Cocoa code 256 | Query/invocation retained; generic macOS/default-app recovery message | R; underlying cause/default handler not established; do not call it permission denial |
| M/Hana9 Extensionless — eligible ordinary file | Found | Exact file; attempted | Accepted | No separate document-content observation | R; proves eligibility is not an extension whitelist |
| Content-only control: query Hana9ContentToken; M/Control.txt contains token but name does not — exclude | Control absent, zero results | None; no opening | N/A | No destination | R + A; direct metadata exists; not a content-search parity test |
| Path-only control: query Hana9PathToken; M/Hana9PathToken/Neutral.txt — exclude child | Child absent; one name-matching parent-folder result | No child selected/opened | N/A | No child destination | R + A; parent matching its own name is expected |
| M/.Hana9 Hidden.txt — exclude | Absent | None; no opening | N/A | No destination | R + A; attributes/metadata readable, explicit visibility rejection |
| Existing OS temporary-directory fixture Hana9 Temporary.txt | Absent | None; no opening | N/A | No destination | R: attributes/metadata available, ancestor visibility rejects it. This is an app exclusion, **not** proof of a Spotlight Privacy exclusion/unindexed volume |
| One/Hana Search Fixture.app — eligible installation | Found alongside Two | Exact One URL; attempted | Accepted | Native window says `Installation: One` | R + U; separate process present; physical typing not separately checked for One |
| Two/Hana Search Fixture.app — eligible installation | Found alongside One | Exact Two URL; automated and physical attempts | Accepted | Native window says `Installation: Two`; Beam confirmed typing without clicking | R + U + H; same bundle ID does not collapse installations |
| M/Hana9 Rename Before.txt — initially eligible, stale URL after rename | Found and selected, then owned fixture renamed to Hana9 Rename After.txt | Old URL attempted | Rejected: Cocoa 260 | Same query/invocation retained; unavailable-location explanation | R; genuine unavailable destination, not injected |
| M/Hana9 Rename After.txt — eligible new URL | Found after live rename | Exact new URL; attempted | Accepted | No isolated document-content observation | R; no index import |
| M/Hana9 Delete.txt — initially eligible, unavailable after deletion | Found and selected, then owned fixture deleted | Deleted URL attempted | Rejected: Cocoa 260 | Same query/invocation retained; unavailable-location explanation | R; marker checked before deletion; no personal file affected |
| Indexed external storage | No external volume mounted | Not attempted | N/A | N/A | N — unavailable hardware |
| Cloud-backed placeholder | No known synthetic cloud-only placeholder available | Not attempted | N/A | N/A | N — provider roots alone do not establish a placeholder; no download/eviction performed |
| Pre-existing Spotlight-excluded/unindexed location | No confirmed suitable location identified | Not attempted | N/A | N/A | N — temporary-directory exclusion above is different; no settings changed |

## Permission and failure matrix

| Case | Observation and recovery | Evidence / limits |
| --- | --- | --- |
| Existing protected `~/Library/Mail` | Hana's read-only `open(O_RDONLY | O_DIRECTORY)` returned `EPERM` (1), including after other grants. No directory contents were read | R: genuine denied operation in Hana's signed identity. No claim that a search/open request reached a protected document, or that TCC rather than another policy is the sole cause |
| User-folder privacy prompts | Beam allowed prompts during native runs; successful D/M/L coverage followed | H + R; exact per-folder prompt sequence/grant state uncertain. No mandatory permission setup added |
| Permission revocation / denied file-opening via Workspace | Not deliberately induced; no permission revocation performed | N; the Mail directory probe is not a denied document-opening test |
| Deterministic denied opening | Injected Cocoa permission failure preserves query, selected identity and invocation; UI explicitly says access was denied and suggests checking permissions in Finder | A: denial-red.txt → denial-green.txt; not macOS permission evidence |
| Genuine unavailable file | Real stale renamed/deleted URLs produce the unavailable-location explanation, retaining context | R; native adapter also tested with a nonexistent synthetic URL (A) |
| Unknown native opening failure | Uncommon extension failed with Cocoa 256; no guessed cause; UI suggests checking Finder and the default app | R; file remains eligible/discoverable |
| File source fails, apps available | Available application can still be selected/opened and activated while file source reports failure | A: `failedFilesStillAllowAvailableApplicationOpening`, existing Search partial-source tests. Controlled source failure, not a real Spotlight permission failure |
| Empty / delayed source | UI distinguishes searching/partial/failed states; completed empty result says indexing/access can limit results | A + R + observed native UI; no “no files exist” or inferred denial claim |

## Change, checks and limitations

A failing seam test exposed denial being described as “may have moved.” Mac Interaction now classifies known Cocoa/POSIX denial and missing-resource errors, with an honest fallback for other errors. File availability validation preserves filesystem errors off the input actor instead of collapsing boolean existence/readability results to “missing.” Error logging records domain/code only. Search results, selection, query, and PR #17's visual styling are preserved; `BarStyle.swift`, `SearchResultsView.swift`, and the logo asset have no diff from the base.

Focused destination suite: 15 tests passed. Final `xcrun swift test`: **44 executed tests passed; four opt-in indexed stress/punctuation tests skipped** (runner reports 48 total). [Full output](full-tests.txt). The real installed-app coverage above is separate from these terminal tests. Debug/release builds and strict signing passed. No broad performance/p95 claim is made; validation probes and automatic opening contaminate timing conditions. Candidate IME remains deferred. Parent #2 lifecycle/performance completion and #10 are outside this ticket.

The remaining unobserved per-document displays and unavailable environmental cases are explicit above. Core file/app opening and physical destination focus have positive evidence. No additional permission/scope change is proposed. [Two-axis review](review.md) records the final review status.

## Documented capabilities (not runtime proof)

- **D:** [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery) has gathering and live-update phases and configurable scopes/predicates; it does not guarantee completeness or grant file access. The implementation matches filename metadata and verifies literal names.
- **D:** [NSWorkspace URL opening](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:configuration:completionhandler:)) reports an application or error asynchronously. This report records acknowledgment separately from destination display/focus.
- **D:** [URL reachability](https://developer.apple.com/documentation/foundation/url/checkresourceisreachable()) documents that direct operations with error handling are preferable when immediately operating on a resource. The file adapter preserves actual attribute/open errors rather than inferring permission state from an empty index.

Apple primary documentation was rechecked on 2026-10-13. The local SDK's `LaunchServices/LSConstants.h` was also inspected; no OSStatus-specific cause is attributed to the observed generic Cocoa 256 error.
