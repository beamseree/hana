# Combined AC10 — unmerged #28 + #29 validation

This is an isolated validation state, not a merge to main or either feature branch.

| Input | Reviewed commit | Draft PR |
| --- | --- | --- |
| Common base | `210e9f34de86d751de6eb80a584cc41cde560ee3` | — |
| Full export (#28) | `0592aab17803b2f1a0e5978af2f51aa4494a1bd8` | [#44](https://github.com/beamseree/hana/pull/44) |
| Manual snapshots (#29) | `9dc752d07be3496f2c4f65d246a25990c15f3473` | [#45](https://github.com/beamseree/hana/pull/45) |

The export commit's tested production source is `2f34bfb`; the snapshot commit's tested production source is `f65db15`. Their final commits add evidence only. The validation applies both pinned diffs to the base, with no `git merge` and no PR merge. It preserves the identical Recovery namespace, both harness dispatch/error sets, snapshot-required read/emit visibility and both appended documentation sections. There are no extra production changes.

## Reproduce

Create a genuinely disposable worktree at the common base. In the feature checkout, run `python3 docs/evidence/issue-22-combined/assemble.py /absolute/path/to/disposable/hana`. The script requires a clean base checkout and applies the exact pinned diffs. Copy `CombinedCollectionJourneyTests.swift` from this evidence directory to its `Tests/HanaTests/` directory. Then, from that disposable worktree:

```sh
./scripts/build
mkdir -p build/combined-evidence
HANA_EXECUTABLE="$PWD/build/Hana.app/Contents/MacOS/Hana" \
HANA_COMBINED_ROOT="$PWD/build/combined-evidence/fixture-$(uuidgen)" \
HANA_COMBINED_REPORT="$PWD/build/combined-evidence/journey.json" \
xcrun swift test --no-parallel --filter CombinedCollectionJourneyTests
```

Only `--collection-fixture` subprocesses run. The root is new, explicitly marked disposable and separate from personal storage. The fixture builder and final comparison run against production Store in the debug test host; restart/export/snapshot/list/inspect/disposable reopening run in separate processes of the signed release binary. `IndependentExportDecoder` comes from #28's test-only independent decoder, not Recovery's own validator. The validation test is stored here because it requires both features; neither PR imports the other's production source.

## Journey and comparison

Build the shared organized fixture (7 notes, 14 tasks) through Store commands, close it, then open it in a fresh signed process. Export in another fresh process; independently reconstruct every domain record and ordered view, comparing exact Markdown bytes. Create/list/inspect the manual snapshot in fresh processes. Move the source Collection directory and all sidecars aside, then reopen a copy of the snapshot in another fresh process. Finally compare the disposable Store's entire records and Notes/Archive/Inbox/Today/Completed/archived-task views against both the original and reconstructed export. Check that the published database and manifest remain byte-identical and that the new Store generation differs.

This covers IDs, collection identity, exact note/task text, timestamps/revisions, note pins/archive, manual Inbox/Today order including renumbering, and independent completion/archive combinations. It establishes ordinary fresh-process persistence and backup/reopen usability, not crash/power-loss safety or production restore. No native UI, installation, retention, schedules, replacement restore or migration handover is involved.

## Test exclusions

No native testing slot was acquired. Exclude `NativeEditingTests`, `MacInteractionTests`, `DestinationInteractionTests`, `ResultIconInteractionTests` and opt-in `SearchResponsivenessTests`. Report non-native checks only. The individual feature evidence retains timing/ownership failures from earlier broad concurrent runs; explicit `--no-parallel` is used for final broad validation. No unrelated behavior was changed to force a pass.

## Observed result — 2026-10-14

PASS. The dedicated signed journey passed, then all **106 non-native tests in 15 suites** passed in one explicit `--no-parallel` run (15.692 seconds), including the combined journey again. The signed release build and strict signature verification passed. No combined production defects were found; no feature-source fixes or identity changes were needed.

- Local, unmerged validation commit: `ccf17183581a3937850fe8425a3cb4f0fc380747` on `codex/issue-22-combined-validation`. This branch was not pushed or merged.
- Worktree: `/Users/beamsereeyothin/.codex/worktrees/issue-22-combined-validation/hana`, retained for inspection.
- macOS 26.4.1 (25E253), Apple Swift 6.3.3, GRDB 7.11.1; actual linked SQLite/settings appear in the runtime event of [journey.json](journey.json).
- Signed binary SHA-256: `efcc69da5a346497b90269938d9004c8dc9442f159ffd1aaab261dae8d04110c`.
- Combined production source-tree digest: `18de87d2546a24410229c016ac373f68d7e1976d4502c6b7a842523ca6b79d2f` (canonical JSON list of relative paths/file SHA-256 values, including Sources and Package.swift/Package.resolved).

[Identity manifest](identity.json) records every production source hash and confirms all feature-owned source files equal their pinned feature versions; only the agreed harness overlap is composed. [Check excerpts](check-results.txt) record build and test outcomes. The [raw journey report](journey.json) pins both feature commits, fixture/collection/snapshot identities, subprocess actions/status/runtime events and successful full-record/organized-view/byte comparisons.

The complete regression command used the signed combined binary via `HANA_EXECUTABLE` and fresh `HANA_COMBINED_ROOT`/`HANA_COMBINED_REPORT` paths:

```sh
xcrun swift test --no-parallel --skip 'NativeEditingTests|MacInteractionTests|DestinationInteractionTests|ResultIconInteractionTests|SearchResponsivenessTests'
```

Both feature PRs remain draft and all issues remain open for user review. This evidence establishes the bounded combined AC10 journey; it does not claim the deferred native or recovery-hardening acceptance.
