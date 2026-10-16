# Word-paced integration — issue #120

Software for #122–#127 is implemented on `codex/issue-120-integration`, targeting `feature/automatic-switch` through draft PR #130. #121 was pulled with its existing macOS validation; #122 was pulled at `37bac99` and validated here before the remaining work. **#128’s few-days human trial remains open; #120 is not declared complete.**

## Final automated verification

- Tested source: `b31ae3260922790218cbbf7f38b51a62c7573311`.
- Host: macOS 26.4.1 (25E253), arm64. Toolchain: Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`), swift-driver 1.148.6.
- `xcrun swift test --no-parallel`: exit 0. The runner reports **491 tests in 66 suites passed**, in 74.511 s. [Full log](final-tests.log). Eleven environment-gated live-index checks are skipped; they are not claimed as verified.
- All Automatic Switch policy, cache, deletion, withdrawal, wake-up, session-count, diagnostics, menu, adapter, isolated Keychain, shared-transport and dedicated-session suites passed. All native suites, including the three Word-paced suites and existing Enter/launch guards, passed under `.nativeWindowSlot`.
- No automated test calls the real Jev API. Policy tests use injected time and scripted events; native tests use fake classifiers and temporary Stores; HTTP tests intercept requests. The #127 manual models check sent no text or key and performed no inference.
- The pre-existing captured-variable warning at `MacInteractionTests.swift:423` remains visible in the log. It does not fail compilation or tests.
- Stored logs escape carriage returns/Unicode line separators and trim trailing horizontal whitespace for repository hygiene. Raw command output remains in `/tmp/hana-issue-120-context/`.

## Acceptance map

| Ticket | Delivered behavior and evidence |
| --- | --- |
| #121 | Pulled one-shot earliest wake-up scheduling. Existing and new wake-up suites pass. [Original record](../issue-121/validation.md). |
| #122 | Boundaries/adaptive pauses, normalization, two-slot admission, prefix/sequence validity, 1.2 s deadline, menu migration and session counts. Pulled source first passed 421 tests. [Tracer map](../issue-122/validation.md). |
| #123 | Launch cache/LRU/version identity and confidence with related-answer provenance. [Cache map](../issue-123/validation.md). |
| #124 | Deletion bursts, selective cancellation, held answers, native replacement provenance and Enter guard. [Deletion map](../issue-124/README.md). |
| #125 | Withdrawal at the pause (including clear), per-mode veto, legacy settings migration, native text/UTF-16 selection, Escape/Enter and separate counts. [Withdrawal map](../issue-125/README.md). |
| #126 | Typed failures/Retry-After, shared backoff, sorted body, once-per-launch key cache, metadata-only presence check and rejected-key menu status. [Failure/key map](../issue-126/validation.md). |
| #127 | Dedicated retained ephemeral session. No suitable supported, quota-exempt preconnect route was established, so preconnect is omitted as permitted. [Research and validation](../issue-127/validation.md). |
| #128 | Content-free prior counters, settings and Beam’s pipeline assessment preserved; candidate handoff below. Days-of-use observations/counts remain pending. [Trial record](../issue-128/validation.md). |

## Review and repairs

[Independent Standards and Spec reports, with rechecks](code-review.md). Initial Standards review found no documented violations and one P3 fixture-duplication heuristic. Spec review found two P2 gaps: confidence across unrelated text and duplicate cancelled-but-running requests.

One implementer repaired all three: prefix provenance breaks unrelated agreement, launch-wide SHA256 fingerprints deduplicate requests until terminal completion without retaining extra raw text, and the native suites share a fixture with an explicit terminal Search batch. Both original reviewers rechecked code `226d710`: no remaining actionable findings. [Red/green evidence](review-fixes.md). Final serial validation above covers the repaired integration.

The session-count regression was also reproduced for all six legacy strategy/classifier combinations and fixed without changing their firing timing.

## Release and trial handoff

`./scripts/build` passed at the tested source (78.47 s). The release bundle passed plist lint and deep/strict ad-hoc signature verification. [Build/signature log](release-build.log). The installed executable matches the built executable: SHA256 `5f87731b1a5addd15b8e6f860179195711fd6588fb9e8a6e6e24274389b91290`.

Installed and launched in `~/Applications/Hana.app`; the running process resolves to the installed executable. AppKit’s event loop was sampled and a Task capture interface was subsequently observed through the exact installed app path. This establishes process/UI liveness, not human-observed focus or latency. The initial UI-tool attach timed out during windowless startup; the later exact-path attach succeeded.

Trial settings: On; Jev; Word-paced; Stay; threshold 0.70; Block that mode for this text. Only firing and the Word-paced reversal choice changed. Earlier diagnostics remain in the log, with a new reset boundary. Native testing slot released to Beam. [Installed identity, settings and handoff](../issue-128/validation.md).

Automated command delivery and fake-clock deadlines establish neither physical focus nor live classifier latency/quality. Beam’s normal-use assessment is required for #128/#115 and the later #107 decision. No prototype change is merged into `main`.
