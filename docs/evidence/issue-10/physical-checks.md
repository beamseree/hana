# Integrated physical checks — #10

Run on the identity in installed-build-final.txt, with normal sources unless stated. Reply with actual passes/failures/unavailable cases; state flags, screenshots and acknowledgments are insufficient. Use disposable text. Candidate IME is deferred. Do not change privacy, shortcut or global Spaces/display settings.

## A. Six lifecycle combinations

Use a normal foreign app, then that app in its native full-screen Space. In each, test with (1) no Hana working windows, (2) Main plus Mock Note A/B open, and (3) all three minimized. Hana's menu provides open/minimize/close controls. For each combination: click a disposable origin text field, physically Option+Space, immediately type `Hana`, wait for live results, press Escape, type into the origin without clicking. Check no invocation Space jump, no unrelated-window raising, correct empty styling and stable input as results arrive.

## B. Lifecycle transitions

With three working windows, verify Dock and Command-Tab access. A Dock click should reach Main without unnecessarily raising both notes. Check one native yellow-button minimization, bulk minimization, then close all/reopen all/bulk minimization. Report animation endpoints; preserve the earlier unreproduced top-left anomaly as history. After closing the last working window, verify both menu Search and Option+Space. Run three rapid Escape/reopen cycles; a fresh invocation is empty, and reinvoking a visible query preserves it. Outside-click into another app and type without a second click. From a full-screen origin, invoke and Command+2, then type into Mock Note A without clicking; destination Space movement is intentional.

## C. Editing and placement

Physically type English/Thai, select/replace, paste literal `- [ hello *? บันทึก`, undo and redo while results resize. Open the editor's native context menu, Escape it and resume typing. Also click outside with that menu open and type into the clicked app. Invoke on the built-in and both external displays; check usable bounds and stable input through growth. With Main focused and pointer on another display, check placement follows Main. Report bezel/card/shadow/placeholder regressions. Trusted foreign AX placement, disconnect, Stage Manager and lock remain unavailable unless actually exercised.

## D. Destination and asynchronous selection

From another app's native full-screen Space, search `Hana Search Fixture`, navigate to the exact `Two` installation, press Return, confirm `Installation: Two` and type without clicking. Quit only that fixture app afterward. Search `Hana9 Duplicate`, choose the Downloads path, open and verify `HANA9-DUPLICATE-DOWNLOADS`; type without clicking, then undo your temporary typing. Search `Hana9 Documents Folder`, open the exact folder, verify Finder destination. No successful opening should return activation to the invocation origin.

Search `Hana Broken Fixture`, attempt opening and confirm the query/selection remain with a recovery message. For late-batch behavior, relaunch the same installed build with `--diagnostics --validation-file-delay` (five-second artificial delay): choose an app while files gather and open it; in another query keep an app selected until the file batch arrives, verify selection stays on its exact path, then navigate to a file and open it. Continue typing/editing during the wait; the deliberate source delay is not a performance sample. Observe exact destination and typing focus, including the full-screen origin. Quit Hana when finished.

## Measurement limit

Qualitative immediate typing is a physical observation, not a measured p95 under 100 ms. The timing harness records narrower call/delivery/scheduling proxies. No high-speed synchronized physical shortcut-to-display measurement is available in this session.
