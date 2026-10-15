# Strong-match gate — issue #112

Implemented on `codex/issue-112-strong-match-gate`, based on the #110 integration branch (including `f81450a`). PR/integration target is `feature/automatic-switch`, never `main`.

## Scope and interfaces

- `StrongMatchGate.evaluate(rawBuffer:results:appStatus:fileStatus:titles:)` is pure. Its decision is allowed or blocked by one word, strong match with a kind, or collection unavailable. `settled` covers apps and collection; `allSourcesSettled` also covers files. Loading and partial Search sources are unsettled; ready and failed are terminal. An unavailable collection always blocks and remains unsettled.
- One-word detection ignores leading whitespace and preserves trailing whitespace, before Search normalization. Matching uses each result's prepared names, including aliases, and the existing `SearchName` tiers. Folders report the file kind.
- `CollectionTitleSource(store:)` is a Main Actor adapter exposing `snapshot` and `snapshots()` (current value followed by updates). It starts loading until the first Store snapshot, prepares names in memory, and becomes unavailable on missing Store or observation failure/close.
- The Store's `activeSearchEntries` observation combines the existing default `noteSearchEntries()` and `taskSearchEntries()` queries in one committed read. Active notes and unfinished tasks are observed together; no new Search rows are added.

No bar, menu, classifier, model, network, Keychain, or application lifecycle caller changes are part of this ticket.

## Automated evidence

The testing seams are the gate and committed Store behavior approved in #110 Testing Decisions. Each slice recorded red before green:

| Slice | Red evidence | Green evidence |
| --- | --- | --- |
| Raw buffer / one-word rule | `01-raw-buffer-red.txt` (missing gate) | `02-raw-buffer-green.txt` (6 cases) |
| Exact, phrase-prefix, word-start, substring and extension-only tiers | `03-match-tiers-red.txt` (8 failed expectations) | `04-match-tiers-green.txt` (18 match cases plus raw-buffer cases) |
| Availability and settled status | `05-availability-red.txt` (5 failed expectations) | `06-availability-green.txt` (5 test functions, including aliases and folders) |
| Real temporary Store title observation | `07-store-observation-red.txt` (missing title source) | `08-store-observation-green.txt` (2 tests) |

`committedTitlesBlockAndCompletedOrArchivedItemsStopBlocking` creates a real disposable SQLite Store, waits for the first snapshot, saves and archives a note, saves and completes a task, saves and archives another task, and closes the Store. It checks the gate's public decision after each committed transition. The source starts loading, publishes prepared active titles, and becomes unavailable after close. The other source test verifies an absent Store immediately blocks.

Evidence text files have trailing whitespace normalized for repository diff hygiene; test outcomes and the raw-buffer test inputs in source are unchanged.

Final related check:

```sh
xcrun swift test --no-parallel --filter 'StrongMatchGateTests|CollectionTitleSourceTests|CollectionStoreTests|NoteOrganizationTests|TaskLifecycleTests|SearchRankingTests|SearchTests'
xcrun swift build
git diff --check
```

`09-related-tests.txt`: 76 tests across 7 suites passed. `10-build.txt`: debug build passed. Existing sendable-capture warnings in `MacInteractionTests.swift` appeared while compiling tests; this ticket changes none of that code.

## Limits

These are pure-policy and disposable-Store checks. No native window tests, signed installation, app launch, real classifier calls, or human observations were performed for #112. The new components have no production caller yet, so visible bar behavior is unchanged by construction; runtime integration belongs to #113.
