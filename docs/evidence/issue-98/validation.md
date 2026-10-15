# Issue #98 — Optional Markdown preview

2026-10-15, Asia/Bangkok. Ticket branch started exactly at integration `2ccd5f7`. Verified on macOS 26.5.1 (25F80), arm64, Apple Swift 6.3.3. Tests use the agreed presentation-model and Note Editing/Mac Interaction boundaries with disposable fixture Stores.

## Delivered behavior and design slice

A native Preview checkbox switches a note window between its retained plain-text editor and a separate read-only AppKit text view. Returning to source restores the same editor and selection. Existing working-window light appearance, color roles and native chrome remain; prose uses `note.body`, code has a system-monospaced role, subordinate headings have a medium role, quotations use secondary text, and native links are underlined. Preview does not execute HTML or create image attachments.

The exact-pinned Swift Markdown parser and source mapping run off the main actor in an explicit `@concurrent` function. The replaceable parser returns only immutable Sendable presentation values. Every request carries local text revision and visibility identity. Changing text, hiding/reopening preview, closing the session or destroying its controller prevents stale results from publishing. Cancellation is an optimization; identity/revision checks establish correctness. Preview never calls a Store writing command or rewrites source text.

Headings, paragraphs, emphasis/strong, unordered/ordered/nested lists, block quotes, inline/fenced/indented code and links have native presentation values. Tables, strikethrough, task-list syntax, thematic breaks, images and raw HTML retain literal source. UTF-8 range conversion preserves Thai, emoji and CRLF/CR. Reference definitions omitted or absorbed by cmark source ranges are retained; uncertain ranges conservatively render the containing block or full note literally. Remote/reference images have no fetch or image-rendering representation. Only an explicit native link click reaches the default-browser opener.

## Automated checks

- `parser-red.txt` and `stale-red.txt` record the absent parser/preview APIs before their vertical implementations. `reference-red.txt` records a real cmark range case that initially dropped a definition before an image; the conservative containing-block fallback fixes it.
- `focused-tests.txt` records seven passing tests in three suites (including fifteen literal fixture cases) covering supported presentation values, fifteen literal/Unicode/newline/nesting fixtures, the absorbed-reference regression, deterministic stale old/new parser completions, same-text hide/reopen request identity, native preview control/first-responder selection, read-only rendering, explicit native link dispatch, committed-byte preservation, and existing note TextKit/undo/composition/newline/long-note regressions.
- After merging integration `cb906c7` (#97), `merged-tests.txt` records the same seven passing parser/native note tests. `capture-regressions.txt` records twelve passing tests across native preview and Note capture opening, including newer-invocation focus ownership. The merged constructor retains #97’s latest-focus-token guard.
- `build.txt` records the original release app build and ad-hoc signature verification; `merged-build.txt` records a passing release rebuild and signature check after #97 integration. Full dependency identities and complete bundled license notices are in [dependencies.md](dependencies.md), `Package.resolved`, and `App/Resources/ThirdPartyNotices.txt`.

Native fixture tests acquire the atomic `/tmp/hana-spec-88-native-lock` slot and use the existing CLT Testing wrapper. As established in #91, the runner keeps the main window open and closes registered note windows synchronously after explicit flush/Store-close cleanup. An initial `performClick` runner attempt ended without a suite summary and is not counted as a pass; the native control is now driven through its standard action dispatch. One initial renderer assertion read before the observation-driven native update completed; the final test waits for native text and requires a valid link range before querying it.

## Limits

Fixtures and native control/delegate dispatch establish value/state behavior. They do not claim physical typing/scrolling responsiveness, physical mouse clicks, a real external browser launch, human visual acceptance, full-screen/Spaces focus, or IME candidate behavior. No real image endpoint is requested: the model/renderer structurally has no loader and the native opener is observed only after an explicit fixture link click. Broader working-window app-loop and physical acceptance belongs to #99; ADR 0005 remains proposed.
