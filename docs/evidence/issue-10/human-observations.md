# Human observations — final installed source ac4138a

2026-10-13, this #10 chat. These are user replies to explicit procedures, not inferences from logs.

1. Six combinations: normal foreign app and native full-screen Space, each with no working windows, all three open, all three minimized. Procedure: physical Option+Space, immediately type Hana, receive live results, Escape and type back into origin without clicking; check stable input, no invocation Space jump or unrelated raising. Beam: **“All six pass.”** Grouped observation, not six individually timestamped traces.

2. Lifecycle transitions: Dock/Command-Tab, Main-only Dock reopening, single yellow-button/bulk/close-reopen-bulk minimization toward Dock, menu and hotkey after last close, three rapid fresh-reopen cycles, same-query reinvocation, outside-click typing, full-screen origin → Command+2 → immediate Mock Note A typing. Beam: **“All lifecycle transitions pass.”** Grouped confirmation. Original minimize anomaly is not reproduced here; no cause or fix established.

3. Native editing/display/style: physical English/Thai, select/replace, literal paste, undo/redo during growth, native context-menu Escape/resume and outside-click/type, three-display placement/bounds, owned-window precedence, stable input and PR #17 bezel/card/shadow/placeholder. Beam: **“All editing, display and styling checks pass.”** Grouped confirmation; candidate IME was not requested or inferred.

4. Normal-source destination check from full-screen origin: Beam reported **“1 works, but nothing shows up when i type hana9.”** Item 1 was exact `Two` application selection, destination identity and typing without a click. File/folder and opening-failure items were not passed. The trace corroborates a completed zero-result query; shell inspection found the named fixtures still present, which is not app-access evidence.

5. The same installed binary was relaunched with the existing #9 coverage probe (no rebuild). Beam reported **“it asked for desktop folder permission just now.”** The probe's Desktop resource attributes/name were readable, but the search procedure was interrupted; its end marker says `finished=false`. This is not a successful coverage run or proof of why earlier metadata was empty. The user was asked whether to allow folder-specific Desktop/Documents/Downloads prompts or keep current access; no agent accepted a privacy prompt or changed settings.

6. Follow-up clarified the original destination procedure: **“1 works, 2 download option doesnt show, only desktop and documents, 3 works, broken works.”** This confirms exact Two app, exact Documents folder, and broken-app context retention; it does not confirm any duplicate-file destination/typing. Beam repeatedly reported the Downloads duplicate missing.

7. Beam then reported **“I allowed full disk access just now but had to quit and reopen.”** This is a user-reported FDA grant and restart, not an agent settings change or a verified TCC inventory. Subsequent checks must be distinguished from earlier permission-conditioned runs.

8. Final five-second delayed-file-source check from a native full-screen origin, after user-reported FDA and restart: Beam answered **“1 works, 2 works i think, 3 that works.”** Item 1 selected Downloads duplicate, verified HANA9-DUPLICATE-DOWNLOADS and typing without clicking/undo. Item 2 kept exact Two selected through delayed file arrival, then opened/typed; this is **tentative** because of “I think,” not an unequivocal selection-stability pass. Item 3 opened the exact `~/Hana Issue 10 Validation/Hana Search Fixture.txt`, verified HANA10-LATE-BATCH and typing without clicking. The grouped procedure asked that successful opens stay at the destination; items 1/3 are confirmed under that procedure. The five-second delay is intentional, not a performance result.

## Timing follow-up — definitive late-batch app check

2026-10-13, unchanged installed source `ac4138a`, executable SHA-256 `cc19d09a7d6d0a72cbc03ff402f3bc69dec98ef79df511493e75c13ffa46571b`, `--diagnostics --validation-file-delay`, two displays recorded at startup.

Procedure sent: From another app’s native full-screen Space, Option+Space → search “Hana Search Fixture” → select the application row whose path contains “/Two/” while files are pending. Stop editing the query, wait for the .txt result to arrive, confirm the same Two app stays selected, Return, confirm “Installation: Two”, type without clicking and remain at that destination.

Beam’s exact answer: **“yes”**. This closes the earlier tentative “works i think” result for this explicit grouped procedure. The [runtime trace](timing-followup/physical-runtime.jsonl) is separate corroboration of batches/open acknowledgments, not a record of query text, exact path, physical typing or focus. No other functional cases were repeated. Physical latency quantiles and physical stall attribution remain unmeasured.
