# Unlocked release verification — 2026-10-16

Beam confirmed unlocked/ready. Root queried `IOConsoleUsers`: `consoleScreenLocked=false` before validation and again after the release smoke. Source970b12b differs from reviewed release source df98878 only in documentation/evidence. The existing signed hashes in final-identity.json remain exact. All native processes ran sequentially under the atomic slot; fixture invocations were explicit and used marked disposable Stores. No installed-app termination, live Collection content, shortcut/Spaces/TCC change or installation was performed.

- Signed release MainWindow validator: exit0 and `main-window.validation-passed`; includes native menu/scoping/section/preview checks.
- Signed release OpenNoteCapture validator: exit0 and `open-note-capture.validation-passed`; includes exact newer-invocation key/query/no-window assertions.
- Signed release NoteWindow validator: exit1, `keyboard-archive`. Trace shows note becomes key after main opened and Pin committed. Cause under investigation; this is not a pass and is separate from prior locked-session failures.
- Release two-process orderly quit/relaunch: both phases exit0, exact UTF-8/stable IDs/task orders pass. Uses new marked final-release-smoke-fixture root, preserves physical fixture separately.
- Unchanged full suite: **394 tests /57 suites,7issues,80.228s**, complete summary and exit1. Five issues in key-scoped MainNoteOrganization menu test; two in OpenNoteCapture newer-invocation global key/responder test. All other tests pass. Isolated menu probe also failed with five issues. Signed actual-app passes do not erase these unit-runner failures.

Original logs are SHA256-identified here and retained unchanged outside the repository. Repository copies replace personal worktree prefixes and visualize trailing literal whitespace, including carriage returns as `␍`. Physical acceptance and native drag/drop commit remain pending.
