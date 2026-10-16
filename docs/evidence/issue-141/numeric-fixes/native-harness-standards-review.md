# Final standards review

Reviewed exact HEAD `d54049ebef3f4674a27840fbfae0c12d3fed7e78` against `924766b4c3881d84e9223790212d1e4615330224` using the three-dot diff. Confirmed **2 commits, 4 files, 157 insertions and 68 deletions**. The incremental commit is `d54049e test: preserve joint pending-close safety assertion`; its predecessor is `6a148ed test: run note close safety checks in owned app loop`.

## Documented standards

**No violations found.** Standards sources remain `AGENTS.md`, `CLAUDE.md`, `docs/agents/domain.md`, `docs/agents/issue-tracker.md`, `GLOSSARY.md`, `docs/product-spec.md`, relevant `docs/technical-design.md` sections, ADR 0002/0005, and the `write-swift` skill. No CODING_STANDARDS or CONTRIBUTING file exists.

The opt-in validator preserves AppKit/native NSTextView ownership (ADR 0002), uses a newly marked disposable Collection Store, and exercises actual close/sheet dispatch. The incremental change restores one joint pending predicate—`arrivals == 1 && held && sheet`—before Saving status, actions and activation policy checks. Its main-actor isolation and synchronized writer callback do not breach the Swift guidance. No normal product route, skipped assertion or simulated focus is introduced. It does not convert automated native state into physical acceptance or acceptance of proposed ADR 0005 (`docs/agents/domain.md:12-14`, evidence separation rule).

## Baseline smells — judgement call

One retained, optional **possible Duplicated Code** smell: `Sources/Hana/NoteCloseValidation.swift:132-140` repeats the pasteboard snapshot/restore helper in `Tests/HanaTests/NoteSaveSafetyNativeTests.swift:241-249`, including:

```swift
let saved = (pasteboard.pasteboardItems ?? []).map { source in
// ... preserve every advertised pasteboard type ...
defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
```

Sharing the routine could avoid future drift. Retaining this small duplication is reasonable for this bounded correction because sharing it would expand a production helper seam across validation/test targets. It is **not a hard violation or blocker**. No additional baseline smell warranted a finding.

No tests/apps were launched, repository files edited, GitHub mutations made or work delegated. Parent-supplied focused-run counts were not independently rerun.

Total: **0 documented-standard violations; 1 optional heuristic; no blockers.**
