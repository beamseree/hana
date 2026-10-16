## Spec

No actionable findings in the working-tree changes since `da37269f906bf52461e0a9fff89fa3bb29b48a7d`, including the new pipeline transport and policy/native/transport tests.

The latest user requirement, "up to 3 parallel Jev requests every 100 ms," is implemented as a Jev-only firing option: changing snapshots are coalesced, unchanged snapshots are not continuously resent, starts have at least 100 ms spacing, and shared transport admission retains occupied slots until cancelled work actually exits. The production classifier factory now uses this shared limiter for the pipeline option, including across invocation teardown/reopen; legacy Jev firing and Foundation Models retain their prior transports.

"Allow prefix verdicts while typing" uses append-only exact UTF-8 prefixes, rejects replacement/deletion/composition-invalidated work, and prevents an older response from overriding a newer handled response. The current gate, probability threshold, multiline Task, Enter, save and composition restrictions remain in the apply path.

"Stay in capture mode after switching" is implemented when the candidate selects `afterSwitch = stay`; switching cancels remaining classification work. "Backspace or delete the whole thing ... switch back" retains the existing Backspace-at-start reversal and adds empty-buffer return to Search plus rearming, including after reversal suspension. Native tests exercise both routes and preservation of current text/selection when applying a prefix verdict.

The requested installation, candidate preference selection, draft status and human responsiveness trial are orchestration/interactive steps outside this source review. This review was read-only; no tests or native actions were run by the reviewer.

Spec findings: 0. No scope-creep findings.
