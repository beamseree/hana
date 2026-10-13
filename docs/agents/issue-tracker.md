# Issue tracker: GitHub

Specs, implementation tickets and bugs live in [beamseree/hana-searchbar](https://github.com/beamseree/hana-searchbar/issues). This is a private repository with a temporary name. A request to publish a spec means creating or updating a GitHub issue there. Read existing issues before creating a duplicate.

## Access

Use `./scripts/github` from the project root, or the connected GitHub tools with `repository_full_name: beamseree/hana-searchbar`. The script runs the installed `gh` CLI using an existing `GH_TOKEN`/`GITHUB_TOKEN`, or the standard Git HTTPS credential helper for `github.com`. It neither stores nor prints a token. The existing personal-repository credential is sufficient; setting up this tracker did not grant new scopes. If the helper has no credential, authenticate through the normal GitHub flow rather than putting tokens in project files.

Always name the repository explicitly in CLI issue/PR operations, especially when working inside the independent local prototype repository.

```sh
./scripts/github issue list --repo beamseree/hana-searchbar --state open --json number,title,labels
./scripts/github issue view NUMBER --repo beamseree/hana-searchbar --json number,title,body,labels,comments
./scripts/github issue create --repo beamseree/hana-searchbar --title 'TITLE' --body-file /path/to/body.md --label ready-for-agent
./scripts/github issue edit NUMBER --repo beamseree/hana-searchbar --add-label ready-for-agent
```

Use UTF-8 body files for multiline issue, PR and comment text. Read the issue and applicable project documents before changing scope. Use [triage-labels.md](triage-labels.md) for label semantics; readiness requires sufficient scope and acceptance criteria.

## Specs and implementation tickets

The accepted product specification remains authoritative. `to-spec` synthesizes a bounded milestone into a parent issue; `to-tickets` creates linked implementation work. Link child tickets through GitHub sub-issues. Use native blocking dependencies when available; otherwise put `Part of #N` and `Blocked by: #N` references in issue bodies. A ticket is unblocked only when its blockers are closed.

Use `gh issue create --help` / `gh issue edit --help` through the wrapper to inspect supported sub-issue flags before use. GitHub's REST dependency operations require the issue database ID, not its displayed issue number.

Close implementation tickets only when their acceptance criteria have verification evidence, normally through a merged PR with `Closes #N`. For a research/prototype record, report observations, limitations and artifact links before closing. Documentation-only setup is not implementation completion.

**PRs as a request surface: no.** Pull requests implement tracked work; external PRs are not automatically part of the triage queue.

## Local and remote source

The root repository's `main` branch contains project documentation and tracker configuration. The throwaway prototype is published on `prototype/window-focus`, under `prototypes/window-focus/`, with its original commit history preserved as ancestry. The existing local nested prototype repository is retained and ignored by the root repository. See [prototype access](../../prototypes/README.md) before checking out prototype branches; use a separate clone so the nested local experiment is not overwritten.
