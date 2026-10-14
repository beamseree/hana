# Issue #49 — steady Search while typing

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
