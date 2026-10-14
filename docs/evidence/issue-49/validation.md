# Issue #49 — steady Search while typing

## Latest decision — restore first-fresh-result replacement

On 2026-10-14 Beam requested undoing `696bdb3` because waiting for both sources left the initial search empty too long. The rollback restores the implementation and tests exactly to `a4cab78`: retain displayed rows on edits, replace on fresh matches, and wait for both sources only before publishing an empty result. The card's loading-height retention stays intact. The first-fresh-result follow-up below is the current behavior again.

Code/test equality to `a4cab78` and `git diff --check` were verified. The restored code's prior full-suite result is 146 tests in 21 suites passed with five gated skips; tests were not rerun for this exact rollback. Both read-only review axes reported no findings. A fresh release build and strict installed-signature validation passed.

After Beam authorized restarting Hana, the rebuilt bundle was installed at `/Users/beamsereeyothin/Applications/Hana.app`. PID `39576`, launched at `2026-10-14 12:43:19 +0700`, loaded UUID `7B07F537-2C6B-3472-B1AE-939AD18829FE`, matching built and installed executables. Both executables have SHA-256 `aa77054fa5d9af7f9603572a5ec15d397d5dc72f9c60a93ab463da4e80b0d68e`. The testing slot was returned to Beam; perceived responsiveness remains a hands-on observation.

## Follow-up — retain displayed rows until fresh results

On 2026-10-14 the user requested that typing and backspacing preserve even nonmatching displayed rows until replacements load. This supersedes the immediate-removal behavior in the original implementation record below.

Mac Interaction now keeps its displayed snapshot across edits. It replaces that snapshot when the current request supplies a visible fresh match, or when both sources finish. Empty or cache-only intermediate updates cannot remove previous rows. Clearing the query still clears immediately. Selection resets to the first displayed row on edit; Enter captures that visible destination, including a retained row. The existing loading-height retention remains intact.

Search marks batches with `hasFreshResults`, calculated from the latest raw source snapshots and the ranked visible identities. Matching the source-local names prevents a retained alias from falsely identifying a result as fresh. Current-query matching and generation cancellation remain enforced within Search; only the presentation layer retains the previous displayed snapshot.

### Verification

- Regression fixtures cover forward typing, backspacing, replacement, empty pending updates, fresh loading matches, final no-results, and Enter on a retained visible row. A separate regression reproduced the cache-only update removing a previous row before fresh results arrived, then passed after the freshness fix.
- Focused Search and Mac Interaction tests: 56 tests in four suites passed in 11.920 seconds.
- Final `xcrun swift test --no-parallel`: 146 tests in 21 suites passed in 27.498 seconds. The same five environment-gated live-index tests listed below were skipped.
- Final `./scripts/build`: release build and bundle-signature validation passed.
- Separate standards and spec reviews reported no remaining findings after the cache-only replacement fix.
- The user explicitly authorized the native testing slot, installation and relaunch. The slot was released after verification. Native fixture assertions are automated evidence; perceived motion and physical keyboard routing remain for the user's hands-on test.

### Installed identity

The final bundle was installed at `/Users/beamsereeyothin/Applications/Hana.app` after quitting the previous Hana process. The installed signature passed verification. PID `36650`, launched at `2026-10-14 12:28:31 +0700`, loaded Mach-O UUID `773EA9B2-7F77-3340-8FE1-907B5BAED372`, matching both built and installed binaries. This was checked with a process sample, not inferred solely from the file on disk. An earlier installation had a disk/process mismatch; the loaded-image check resolves that ambiguity for this handover.

| Artifact | SHA-256 |
| --- | --- |
| Release executable, built and installed | `eeae1aed9f08c8e2789a535accc99bfbff6fb3c60b14a6c8a0c2f021cb0f5fcf` |
| `.build/debug/Hana` | `6fae638c59631015cd135231b0fef1e6db0ec7b5f1352db6d86803618cf46fe4` |
| `.build/debug/HanaPackageTests.xctest/Contents/MacOS/HanaPackageTests` | `7685757205cab83ed9329a49dc8d3765570d38591ceef7a0a4aa73e66de4f5bb` |

## Original implementation record — b071801

Verified on 2026-10-14 against the implementation commit containing this record, on `codex/issue-49-steady-search`. Starting revision: `680bb1e1c146eadc172ff03e5d31fc4fc935818d`.

## Change

Search returns a synchronous, bounded initial recheck followed by asynchronous source updates. Iterating the response always delivers the initial batch first. Mac Interaction applies that batch in the edit callback, so unmatched old rows cannot be selected between the edit and a source response. App results have no fixed delay; the existing 100 ms delay applies only to files. Source replacement carries only previously visible matches while loading, preserves source-local aliases, and drops removed matches when their source finishes.

The card holds its height while either source loads, including when an edit interrupts a previous shrink animation. Ready, partial and failed statuses all finish a source. Loading uses a small native spinner in the input row; failure, partial-limit, opening and open-failure messages retain the status row. Each edit selects the first result and resets scrolling. Selection follows the first row until explicit navigation; losing a navigated result resumes following the first row. Enter still captures the visible selected destination before asynchronous opening.

## Automated evidence

- `xcrun swift build`: passed with Swift 6.3.3 on macOS 26.4.1 (25E253).
- Focused Search and Mac Interaction tests were run throughout implementation. Rechecked delivery, app delivery during a pending file delay, retained loading matches, selection fallback, loading presentation, interrupted shrink, synchronous edit selection, and alias ownership each reproduced a failing assertion before their fix.
- `xcrun swift test --no-parallel`: passed, 144 tests in 21 suites, 24.761 seconds. Five environment-gated tests were skipped: live indexed responsiveness, three bounded indexed-fixture checks, and the literal indexed-file fixture check.
- Search fixtures cover deletion and replacement, reranking before source responses, retained matches during loading, file-only debounce, source-local alias removal, exclusion of never-visible carryover, cancellation, stale generations, ranking and existing eligibility behavior.
- Mac Interaction fixtures cover letter-by-letter height retention, contraction for ready/partial/failed completion, clearing, an edit during a shrink, input-row loading without a status row, no-results only after completion, synchronous rechecked selection, top following, scroll reset, navigated identity across reorder, removal fallback, visible Enter capture and existing obsolete-open guards. Native editor retention, selection and undo checks passed in the full suite.
- `git diff --check`: passed.

Debug build SHA-256 values used for the final suite:

| Artifact | SHA-256 |
| --- | --- |
| `.build/debug/Hana` | `070bac77d8ceadf0ad750c880e013dcb0632a455506eefb0f81e6e53c4b978db` |
| `.build/debug/HanaPackageTests.xctest/Contents/MacOS/HanaPackageTests` | `78fac940c38c9fb92496c462342c3d55e2cf03aa3e762432b2d14909a299769d` |

## Review

The code-review skill ran separate standards and spec reviews against the starting revision. Standards review identified unbounded accumulation of loading candidates; spec review identified unfinished shrink and transient stale-row selection. All were corrected and re-reviewed. A related source-alias ownership regression was also fixed and tested. Both final reviews reported zero remaining findings.

## Evidence limits

The user explicitly handed over the native testing slot for these AppKit fixture tests and the full suite; the slot was released afterward. These tests present real panels and observe programmatic results, selection, scroll position and content height. They do not establish physical keyboard routing, perceived animation quality, or installed-app latency. No app was installed, no privacy settings were changed, and no live-index performance or coverage claim is made. #50's typing-pause timing and broader #47 performance validation remain separate work.
