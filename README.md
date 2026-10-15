# Native macOS shapeshifting search bar

Hana is a personal native macOS app combining app/file search, quick note and task capture, and a collection organizer. The transforming bar has an opaque white card inside a translucent bezel.

## Status

Product scope was confirmed on 2026-10-13. The app supports native invocation, mixed application/filename Search, exact-destination opening, and durable Note and Task capture. The main window shows saved notes as they commit. Working-window organization and note editing are tracked in [#88](https://github.com/beamseree/hana/issues/88). See [build/run/test instructions](docs/native-shell.md), the [product specification](docs/product-spec.md), and the per-ticket records under [docs/evidence](docs/evidence). Automatic backups and restore remain deferred; Hana is not yet a safe sole home for important content. The isolated prototype remains on `prototype/window-focus`.

## Start here

- [Product specification](docs/product-spec.md): accepted behavior, references, acceptance criteria, and interview decision history.
- [Glossary](GLOSSARY.md): shared domain language.
- [Design system](docs/design-system.md): color roles on Vercel Geist's palette; other sections to follow.
- [ADR 0001 — Own tasks and notes](docs/adr/0001-own-tasks-and-notes.md): the ownership decision and its rationale.
- [Technical design](docs/technical-design.md): architecture, environment evidence, source links, recovery contracts, validation strategy, and phased implementation plan.
- [ADR 0002 — Native windows and text](docs/adr/0002-appkit-windows-and-native-text.md), [ADR 0003 — Transactional collection](docs/adr/0003-transactional-local-collection.md), and [ADR 0004 — Direct installation](docs/adr/0004-direct-installed-personal-app.md): selected engineering decisions.
- [ADR 0005 — Activation policy](docs/adr/0005-activation-policy-and-working-windows.md): proposed implementation with positive interactive evidence and explicit remaining limitations.

These project-local documents are the working source of truth from this handoff onward. BeamOS retains a historical copy; this project does not depend on the vault or its workflows.

## Next work

The window/focus prototype supports continuing with a single-process design on the tested Mac. Full-screen invocation, Dock/Command-Tab access, minimized windows and three-display pointer placement have user-observed evidence. The reported minimize anomaly did not recur in three follow-up checks; its original cause remains unknown. Candidate-based IME testing is explicitly deferred for current English/Thai use.

Working windows and organization are tracked in [#88](https://github.com/beamseree/hana/issues/88). Notes/tasks in Search, Settings, automatic backups and restore belong to later work. Ad-hoc signing is local development evidence only. See the [technical design](docs/technical-design.md) and [prototype evidence](prototypes/README.md).

## Working windows

Open **Hana → Open Hana** from the menu-bar menu, **Window → Open Hana** (Command+1), or the Dock icon to reach the single main window. Working windows retain Dock and Command-Tab membership while open or minimized; closing the last window returns to accessory mode. The mock windows used in the earlier shell milestone were removed in [#89](https://github.com/beamseree/hana/issues/89). See its [evidence](docs/evidence/issue-89/validation.md).

## Tracker

Use [GitHub Issues](https://github.com/beamseree/hana/issues) for specs, implementation tickets and bugs. [Tracker conventions](docs/agents/issue-tracker.md), [triage labels](docs/agents/triage-labels.md), and [domain-document rules](docs/agents/domain.md) are shared by `AGENTS.md` and `CLAUDE.md`.

No further product interview confirmation is pending. Model-assisted classification (including the user-supplied Typesafe Jev reference) is future exploration, not a first-version dependency.

## Completion evidence

[Issue #1](https://github.com/beamseree/hana/issues/1) records the completed window/focus experiment, its artifacts and remaining limitations.

The specification includes the accepted end-to-end verification loop. Source changes alone do not establish that keyboard focus, animations, file search, persistence, export, or recovery work on the target Mac.
