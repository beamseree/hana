# Jev pipeline trial — 2026-10-15

Beam explicitly requested up to three parallel Jev requests at 100 ms intervals, acceptance of prefix verdicts during typing, staying in capture after a switch, returning to Search when Backspacing or clearing, and installation while #119 remains draft. This amends the strict changed-buffer cancellation behavior in #110 for a new selectable Jev-only firing mode. Existing modes remain available.

## Behavior

- `Fires → Jev pipeline (100 ms, up to 3)` starts immediately when the gate first allows classification, then sends changing snapshots at least 100 ms apart. A full pipeline retains only the newest unsent snapshot. Unchanged text is not repeatedly sent, except when a second agreeing verdict is requested.
- The session policy and shared live transport both cap concurrency. Shared transport slots last until HTTP work actually exits, even after cancellation or rapid bar close/reopen; cancelled waiters never send. A delayed actor continuation cannot compress the actual transport start interval.
- An answer for an exact UTF-8 prefix may apply to appended text. A newer handled answer supersedes older replies. Deletion, replacement, composition, blocked gates, navigation suspension or loss of eligibility invalidate outstanding work. The current strong-match gate, threshold, multiline Task, Enter and save rules are checked before switching.
- With `After a switch → Stay in that mode`, capture cancels pending classification and stops new requests. Editing the capture retains its mode. Clearing the entire automatic capture returns Search and rearms classification. Backspace at the start returns Search with the text retained and honors reversal suspension until the buffer is cleared.
- Foundation Models retains its previous behavior. The pipeline menu item is disabled for Foundation Models; choosing Foundation Models while pipeline is selected changes firing to the existing 150 ms debounce.
- API model/key handling and classifier wording remain unchanged. The deliberate tricky-input check remains sequential and uses the same fixed fixtures. No new user-content logging is added.

Prefix acceptance deliberately permits a decision based on earlier appended text; later appended words can change intent. This trial measures that tradeoff rather than claiming classifier correctness or instant response. Individual Jev request latency is unchanged by parallel scheduling.

## Verification

Source/test revision: `de98347dcf9e7fd270598bc54f0f56bd47684dbe`. The serial suite ran against the byte-identical code/test working tree subsequently committed at this revision.

- [Policy red reproduction](policy-red.txt), [gate-unblock timing red reproduction](gate-red.txt), and [33 policy tests green](policy-green.txt): injected clock proves spacing/cap, coalescing, prefix acceptance, sequence rejection, edit/IME/gate/eligibility invalidation, timeout cancellation acknowledgment and clear/rearm.
- [Initial focused native run](native-initial.txt): all three new native editor regressions and classifier-menu check passed; an older radio-selection test expected the previous last firing item. Its expectation now names the new final pipeline item.
- [Full serial suite](full-tests.txt): **391 tests in 51 suites passed in 69.662 s**, `xcrun swift test --no-parallel`. Eleven existing environment-gated live-index cases remain skipped. No test called real Jev or Foundation Models inference.
- New shared transport tests use held fake requests: three-slot cap across independent clients, actual start spacing, cancellation before admission, cancelled active work retaining slots, FIFO surviving waiters.
- Native tests use the actual AppKit editor and disposable Collection Store with fake Jev. They verify current text/UTF-16 selection preservation, the existing Enter guard and exactly-once saving, stable capture, clear-all Backspace returning Search, and retained-text reversal/clear/rearm. These are automated command-delivery checks, not physical keyboard/focus observations.
- Separate [Spec review](spec-review.md) and [Standards review](standards-review.md): zero remaining actionable findings. An intermediate transport admission/start timing concern was corrected before the final suite.

Committed log copies escape carriage returns and Unicode line separators and remove trailing horizontal whitespace for repository hygiene; the original command output remains in the local `/tmp/jev-pipeline-*.txt` and `/tmp/jev-policy-*.txt` files.

## Candidate installation

Installed and launched at `2026-10-15T20:04:07.910032+07:00` in `~/Applications/Hana.app`, code candidate `de98347dcf9e7fd270598bc54f0f56bd47684dbe`. Current `main` (`ced5e5f4fa5d7a9561ae5d298201bb897961882b`) was fetched and already included before building. [Release build/signature output](release-build.txt) and [installation/settings record](installation.json) are retained.

Installed executable SHA-256: `eddc754a8e33ddcb097d65667e22005cf8e37152028f74cc3956d8deba4593c6`. The signature passed deep/strict verification, the installed bytes match the preserved release candidate, and the running process resolves to that installed executable. A native Hana main window was visible afterward; this does not prove physical focus or classifier responsiveness. The previous installed app and original option snapshot are backed up under the local `build/jev-pipeline-candidate/installation-20261015-200407/` directory.

Trial settings: automatic switch On; Jev; pipeline (100 ms, up to 3); Stay in that mode; threshold 0.70; one agreeing verdict; Don't wait. Only firing and after-switch preferences changed during installation. Beam's latest Enter behavior (`Saves`), reversal/navigation suspension, Escape and other preferences were preserved. Keychain items and Collection data were not modified by the installer. Native-testing slot released to Beam.

PR #119 remains draft. The original real-provider fixture reports identify the previous candidate; these scheduling changes were verified with fake providers and automated editor checks. Human responsiveness, prefix-intent suitability and days-of-use observations on the new installed candidate remain pending.
