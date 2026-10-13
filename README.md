# Native macOS shapeshifting search bar

Personal macOS app combining app/file search, quick note capture, and task management in a solid-white transforming bar, with a main organizer and separate note windows. The directory name is descriptive; no product name has been chosen.

## Status

Product scope was confirmed on 2026-10-13. The current bounded milestone implements native invocation, mixed application/filename Search, exact-destination opening and three validation-only working windows. PR #17's visual design is retained. See [build/run/test instructions](docs/native-shell.md), [coverage and permissions](docs/evidence/issue-9/validation.md), and [integrated acceptance](docs/evidence/issue-10/validation.md). Capture, persistence and the organizer remain future work. The private repository is [beamseree/hana](https://github.com/beamseree/hana); the isolated prototype remains on `prototype/window-focus`.

## Start here

- [Product specification](docs/product-spec.md): accepted behavior, references, acceptance criteria, and interview decision history.
- [Glossary](GLOSSARY.md): shared domain language.
- [ADR 0001 — Own tasks and notes](docs/adr/0001-own-tasks-and-notes.md): the ownership decision and its rationale.
- [Technical design](docs/technical-design.md): architecture, environment evidence, source links, recovery contracts, validation strategy, and phased implementation plan.
- [ADR 0002 — Native windows and text](docs/adr/0002-appkit-windows-and-native-text.md), [ADR 0003 — Transactional collection](docs/adr/0003-transactional-local-collection.md), and [ADR 0004 — Direct installation](docs/adr/0004-direct-installed-personal-app.md): selected engineering decisions.
- [ADR 0005 — Activation policy](docs/adr/0005-activation-policy-and-working-windows.md): proposed implementation with positive interactive evidence and explicit remaining limitations.

These project-local documents are the working source of truth from this handoff onward. BeamOS retains a historical copy; this project does not depend on the vault or its workflows.

## Next work

The window/focus prototype supports continuing with a single-process design on the tested Mac. Full-screen invocation, Dock/Command-Tab access, minimized windows and three-display pointer placement have user-observed evidence. The reported minimize anomaly did not recur in three follow-up checks; its original cause remains unknown. Candidate-based IME testing is explicitly deferred for current English/Thai use.

The bounded milestone is tracked in spec #2. Issue #10 assesses the integrated native behavior and performance; its evidence distinguishes automated checks, runtime traces, physical observations and outstanding acceptance. Ad-hoc signing is local development evidence only. See the [technical design](docs/technical-design.md) and [prototype evidence](prototypes/README.md).

## Working-window validation

The native shell now includes Main and two separately identified mock note windows for [issue #4](https://github.com/beamseree/hana/issues/4). All content is validation-only. See [controls and run instructions](docs/native-shell.md) and the [current runtime matrix](docs/evidence/issue-4/validation.md).

## Tracker

Use [GitHub Issues](https://github.com/beamseree/hana/issues) for specs, implementation tickets and bugs. [Tracker conventions](docs/agents/issue-tracker.md), [triage labels](docs/agents/triage-labels.md), and [domain-document rules](docs/agents/domain.md) are shared by `AGENTS.md` and `CLAUDE.md`.

No further product interview confirmation is pending. Model-assisted classification (including the user-supplied Typesafe Jev reference) is future exploration, not a first-version dependency.

## Completion evidence

[Issue #1](https://github.com/beamseree/hana/issues/1) records the completed window/focus experiment, its artifacts and remaining limitations.

The specification includes the accepted end-to-end verification loop. Source changes alone do not establish that keyboard focus, animations, file search, persistence, export, or recovery work on the target Mac.
