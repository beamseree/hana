# Issue #140 — remove the Note mode prefix

Validated on 2026-10-16 in `codex/remove-note-prefix`, against the starting revision `8c4fbcdc77a6cdec74dd0a4985448f7d012185ce`.

## Behavior and coverage

Capture Session recognizes only `[` → Task. Typed `-` and `-5 + 3` remain literal Search text; insertion before existing text and other insertion provenances remain literal. Task prefix consumption, multiline refusal and re-arming are preserved. New note, accepted automatic Note decisions, Backspace return, Note editing, saving, retry, dismissal and Open in window retain their coverage. Native Note fixtures choose Search's real New note suggestion; empty fixtures remove temporary setup text and its undo history before the scenario begins.

The glossary, product specification and technical design record removal of `-` on 2026-10-16. No replacement Note shortcut or calculator was added.

## Automated results

TDD used the user-confirmed Capture Session seam. The initial literal-dash test failed on the old prefix map with `consumeInsertion` / `enterMode(.note)` and passed after removal. The final parameterized test inserts `-` and `-5 + 3` character by character, checking Search after every insertion.

- Focused Capture Session and safety run: 66 tests in 7 suites passed.
- Migrated native tests exercised the real AppKit editor and disposable Stores. The multiline Note query observer was reset after its New note setup request settled, preserving the original no-search-during-Note and normalized-return-query assertions.
- Final `xcrun swift test --no-parallel`: exit 0.
- `xcrun swift build -c release`: exit 0, completed in 64.80 seconds. The existing `kSecUseAuthenticationUIFail` deprecation warning in `JevKeychainStore.swift` remains outside this change.
- `git diff --check`: passed.

```text
Test run with 613 tests in 89 suites passed after 110.253 seconds.
```

Eleven existing environment-gated live-index, indexed-ranking and performance checks were skipped. This is a passing default suite, not evidence that those gated checks ran.

The first full run exposed two stale tests. Restoring every changed source and test file to the starting revision reproduced both failures (2 tests, 3 failed assertions). The changes were then restored. Test-only corrections explicitly select New note before Enter under #131's full-text submission behavior, and exclude the disabled shortcut-availability status row from the main menu command list. The focused recheck passed 7 tests in 2 suites; both tests also passed in the final full run.

Full local output: `/tmp/hana-140-final-full.log`; baseline probe: `/tmp/hana-140-baseline.log`; focused stale-test recheck: `/tmp/hana-140-stale-recheck.log`.

## Native build identity

The final suite ran both signed disposable app-loop fixtures successfully:

```text
mode=main-window status=0 marker=main-window.note-menu-assertions-passed
sha256=3f75c1c4ce2ce82903333d2f9afee38c7824cc44728852efb76c71679f565803
mode=open-note-capture status=0 marker=open-note-capture.newer-bar
sha256=c9bbe31d9f987c4a3ebf2c24970d3f02f5a6de8658820951d315d1204c7a3aea
```

Debug executable SHA-256: `62e0b57f74132474762ebd2c2237aa028c477021d563c1b0ce4ee82777961582`. Release executable SHA-256: `b0aae3aadf2666b388078c6c1ab6743fa043b3f3b8227601a9493edb4064fcf0`. The fixture copies have separate signing identities, so their hashes differ.

The user handed over the native testing slot before execution; it was released after the final suite. These are automated native editor and app-loop observations. Physical keyboard feel, human visual acceptance and real-provider classification were not tested here. No installed application was replaced.

## Review

The code-review skill reviewed the complete diff against `8c4fbcd` along independent Standards and Spec axes, including the two baseline test repairs. Standards: 0 hard violations; the optional fixture-deduplication heuristic was resolved by retaining explicit setup branches for test readability. Spec: 0 findings.
