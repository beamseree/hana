# Standards review

Reviewed `924766b4c3881d84e9223790212d1e4615330224...6a148ed886ce88d7bcf01484b228228b302c99e3`: one commit, four files, 152 insertions and 68 deletions. Both refs and HEAD were confirmed. Commit: `6a148ed test: run note close safety checks in owned app loop`.

## Documented standards

No violations found. Sources checked: `AGENTS.md`, `CLAUDE.md`, `docs/agents/domain.md`, `docs/agents/issue-tracker.md`, `GLOSSARY.md`, `docs/product-spec.md`, relevant `docs/technical-design.md` sections, ADR 0002/0005, and the `write-swift` skill. No CODING_STANDARDS or CONTRIBUTING file exists.

The explicit opt-in branch retains AppKit window ownership and native NSTextView editing (ADR 0002, framework rule). The child uses a marked disposable Collection Store, actual `performClose`, attached sheets, Store reads/reopening and real pasteboard bytes. `@MainActor` UI work and synchronized synchronous commit fault injection follow the Swift isolation guidance; the semaphore pauses the writer callback without holding a lock across `await`. The change does not claim physical focus acceptance or acceptance of proposed ADR 0005 (`docs/agents/domain.md:12-14`, evidence separation rule).

## Baseline smells — judgement call

One optional **possible Duplicated Code** smell: `Sources/Hana/NoteCloseValidation.swift:127-135` adds a byte-for-byte copy of the pasteboard snapshot/restore implementation retained in `Tests/HanaTests/NoteSaveSafetyNativeTests.swift:241-249`, including:

```swift
let saved = (pasteboard.pasteboardItems ?? []).map { source in
// ... copy each advertised type's data ...
defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
```

A shared fixture helper would prevent future restoration fixes drifting between the validator and tests. This is a maintenance suggestion, not a standards breach or a blocker for the bounded fixture correction. No other baseline smell warranted a finding.

No tests/apps were launched, repository files edited, or GitHub changes made during this review. Counts supplied by the parent were not rerun or represented as independently verified.

Total: **0 documented-standard violations; 1 optional heuristic finding.**
