# #146 Beam's interactive calculator check

Performed by Beam on 2026-10-26 on macOS 26.4.1 (25E253), arm64, with the installed build of [PR #149](https://github.com/beamseree/hana/pull/149). These are Beam's observations, distinct from the automated checks in [#141 integration validation](../issue-141/validation.md).

## Installed build

- Source: `codex/issue-141-integration` at `78880182e4d057dbb81f6ca90e560aedb46c0588`, the current PR #149 head, from a clean checkout.
- At Beam's request, `./scripts/run` rebuilt the unchanged source incrementally, signed it with the existing Hana Local Development identity (certificate leaf `5c1f81113eccdb4ae9b6d5c89aa22b045a29417b`), installed it to `/Users/beamsereeyothin/Applications/Hana.app` and launched it. Hana was not running beforehand. Strict signature verification passed.
- Built and installed executable SHA-256 both: `bef089d101d33b293a90f19bfb4a4f71a6bc2a802fb4a6dae69791538997449a`. CDHash `3903c639c20d2f8200b18d47a4fcd81c0da0b738` matches the 2026-10-16 installation recorded on #146, so the code is identical; the executable hash differs from that installation's `edc82881…` only through re-signing.
- The running process (PID 9633) was confirmed to run from the installed executable. No settings, permissions or credentials were changed. Search shortcut: Cmd+Space.

## Beam's observations

Beam was given this checklist and reported **“looks good”**:

1. From another app, invoke Search, type `1200 / 3`, press Enter and paste: `400` lands in that app.
2. `0.1 + 0.2`, `-5 + 3`, `200 + 10%`, `2pi`, `3e5` and `1 / 3` each show a correctly formatted answer.
3. `12 *`, `5 / 0`, `sqrt(-1)`, `9^9^9` and `3 + * 4` each show their explanation, and Enter on each closes the bar.
4. `2024` and `rent 1200 / 3` search normally, with the New note / New task suggestions present.
5. With the automatic switch and Debug mode on, a calculation shows "Calculation" in the Debug footer and never switches mode.

The criterion that the answer row appears without visible delay while typing quickly was not in that list. Asked separately, Beam confirmed: “the answer row keeps up with no visible delay when typing quickly.”

## Evidence boundaries

This records Beam's summary report of the checklist, not separate per-item notes. No automated tests, native fixtures or real-provider requests were run for this check.
