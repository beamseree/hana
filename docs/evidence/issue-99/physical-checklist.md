# Working windows — Beam's physical checks

All observations below are **pending**. The launcher now uses the reviewed release at source `11331fc`; [final-identity.json](final-identity.json) records its signed hash and build environment. The full394-test suite, all three signed app-loop validators and the release quit/relaunch smoke passed; physical acceptance remains separate. The launcher checks the signed executable hash and bundle ID, holds the native testing slot for its owned process, and preserves the marked fixture across normal quit/relaunch.

When the agent hands over the final bundle, run the same command for first launch and every relaunch:

```sh
/tmp/hana-spec-88/native/launch-physical-fixture
```

Keep that Terminal open while testing. Quit the fixture with Command-Q while one of its windows is focused. Wait for the command to finish before relaunching. Do not force-kill, delete its data, rebuild or replace the bundle between the persistence steps. The fixture is **Hana Working Windows Fixture**, ID `com.beamseree.hana.validation.issue99`; it uses `/tmp/hana-spec-88/physical-fixture`, with runtime metadata at `/tmp/hana-spec-88/physical-runtime.jsonl`. It is separate from the installed Hana.

The earlier provisional fixture reported Option+Space conflict **-9878** while installed Hana owned it. The final automated release smoke reported registration **0** in both processes. Check the fixture menu when you launch: it must say **Option+Space is available** before global shortcut checks. If it reports a conflict, you may quit your installed Hana yourself, normally quit this fixture and relaunch the same command; otherwise mark shortcut rows unavailable and use its Search/Open Hana menu. No shortcut, permission or Spaces settings need changing.

| Check | What to do and observe | Result |
| --- | --- | --- |
| Foreign native full-screen, windows open | Keep main and Scratch note windows open; full-screen another native app; Option+Space, type without clicking, Escape. Record actual typing destination and Space. | Pending |
| Foreign native full-screen, windows minimized | Minimize both fixture working windows and repeat. | Pending |
| Dock / Command-Tab / final close | Switch to working windows through Dock and Command-Tab, minimize/raise them, close the last one and confirm menu-bar/global access remains. | Pending |
| Escape back to note | In Scratch, invoke the bar, Escape, then type a unique marker without clicking. It must enter the same note editor. | Pending |
| Save back to note | Invoke the bar over Scratch, save synthetic capture text, then type another marker without clicking. Record where it enters. | Pending |
| Thai editing and IME | Type, select, paste and undo Thai; separately exercise marked-text composition/commit if available. Name the input method. Candidate-popup/active-composition Escape remains unverified if not exercised. | Pending |
| Long note | Open **Fixture — Long note** (about 1.26 MB); type a short sustained sequence and scroll. Describe visible delays; no numerical threshold was accepted. | Pending |
| Normal quit/relaunch persistence | Open **Fixture — Quit/relaunch**; keep its title line, type `hana99-persist-001` below it and immediately Command-Q while the fixture is focused. Rerun the same command; reopen that note and confirm the exact marker remains. | Pending |

Optional organizer spot-checks: drag an Inbox task before another row and to the list's end, repeat in Today, inspect Tasks/Archive native menus, rename with Return/Escape, restore archived items, and toggle **Fixture — Preview**. CUA confirmed a native menu reorder and visible preview; **native drag/drop commit remains unverified** after bounded attempts. Please describe the actual order after a drop rather than treating a drag proxy as success.

Reply with each result as pass / fail / unavailable and a brief observation. Automated/runtime/CUA evidence is separate from your physical observations. Failed observations need a fix or your explicit decision to accept/defer them. #99 remains pending and ADR0005 proposed until the gate is satisfied or explicitly deferred.
