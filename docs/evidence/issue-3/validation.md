# Issue #3 validation — 2026-10-13

Implementation branch: `codex/issue-3-native-shell`; review baseline: `fe9681ce96c141d7d10ece6aaff8d01b7ab9cbc7`. This is the native empty Search shell only. Prior prototype passes are not counted as current app acceptance.

## Environment and identity

- macOS 26.4.1 (25E253), arm64; one attached screen reported at current startup (the earlier prototype had three).
- Selected `/Applications/Xcode-26.6.app/Contents/Developer`; Xcode 26.6 (17F113), Swift 6.3.3, SDK 26.5; first-launch status succeeded. No toolchain installation/change.
- Installed `~/Applications/Hana.app`, identifier `com.beamseree.hana`, version 0.1.0 (1).
- `security find-identity -v -p codesigning`: 0 valid identities. Signature=adhoc, TeamIdentifier not set, no entitlements, no sandbox, no hardened runtime. Strict signature/plist checks passed. Code hash is build-specific; final signature details are recorded below after review.
- No privacy grant, shortcut preference, or Spaces setting was changed. The previously running preserved prototype was terminated before normal Hana launch to free Option+Space; its files were read via Git objects and never modified.

## Automated behavior checks

TDD at the agreed Mac Interaction boundary:

- `reinvocationKeepsTheCurrentSession`: initially failed to compile before Mac Interaction existed, then passed against real AppKit.
- `oldDismissalCannotCloseAReopenedBar`: failed because the old invocation cleared the new session; passed after enforcing invocation identity. Covers dismissal, fresh identity and stale callback rejection through the production module interface.
- Native focus is deliberately **not** asserted by either test. They do not simulate a physical keyboard or certify full-screen placement.

## Running-app evidence

| Case | Evidence | Result |
| --- | --- | --- |
| Launch installed signed app | Launch Services launched `~/Applications/Hana.app`; runtime startup reports accessory policy, zero text, hidden panel, level 3, exclusive shortcut OSStatus 0 | Runtime pass; no typing claim |
| Normal physical invoke/type/Escape | Requested from Beam in this chat | Pending |
| Full-screen physical invoke/type/Escape | Requested from Beam in this chat | Pending |
| Outside click and typing in clicked app | Requested from Beam in this chat | Pending |
| Reinvoke retains query; dismiss/reopen is empty | Requested from Beam; session identity automated separately | Pending physical check |
| Menu invocation | Requested from Beam | Pending |
| Exclusive shortcut conflict + menu fallback | Controlled competing registration check planned, without altering system settings | Pending |
| Native English/Thai, paste/undo/context menu | Physical procedure documented | Pending |
| Pointer-display placement | Runtime instrumentation available; physical check pending | Pending; multiple/negative-coordinate displays currently unavailable |

The native automation tool timed out attaching to the app while no ordinary window was open. This repeats a prototype tooling limitation and is not evidence that the physical shortcut fails. Build/signature success, a screenshot and `editorResponder` are not keyboard evidence.

## Remaining scope

Candidate-based IME verification is deferred by Beam. AX focused-window placement, display hot-plug, lock/sleep and Stage Manager are unverified. There are no working windows to minimize in #3; the prototype's unreproduced top-left minimize observation remains recorded in #1 and ADR 0005 without claiming a fix. No architecture ADR is promoted to accepted by this shell build.
