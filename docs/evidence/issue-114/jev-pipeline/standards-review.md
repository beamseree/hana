Standards review — Jev pipeline

Baseline: da37269f906bf52461e0a9fff89fa3bb29b48a7d. Reviewed the working-tree policy, options, menu, ClassifierServices wiring, new JevPipelineTransport and associated policy/menu/transport/native test source.

Documented-standard violations: none found.

Heuristic defects: none found.

The final shared MainActor limiter retains slots until transport termination, checks cancellation after admission, and reserves only one pending admission until the actual caller stamps its start time. This addresses the intermediate admission-versus-start timing concern. Production pipelined Jev instances share this limiter; legacy firing paths retain their existing transport behavior. Policy invalidates non-append changes and composition, checks the current gate, rejects replies older than a newer handled sequence, and rearms after clearing automatic capture. Added diagnostics retain content-free fields.

Sources consulted: AGENTS.md, CLAUDE.md, docs/agents/domain.md, GLOSSARY.md, docs/product-spec.md, relevant native input/evidence/privacy portions of docs/technical-design.md, ADRs 0002/0004/0005, and write-swift SKILL.md (actor transactions, cooperative cancellation, bounded concurrency, Swift Testing and logging privacy).

Read-only source review; no tests, native actions, performance measurements, or live API calls performed by this reviewer. Findings do not establish physical focus, live response latency, or interactive switching quality.
