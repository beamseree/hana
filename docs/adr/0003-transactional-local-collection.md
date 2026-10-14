---
status: accepted
---

# ADR 0003 — One transactional local collection with portable export

Selected on 2026-10-13 as an engineering decision within the authorized technical-design work. Store owned notes and tasks in SQLite through GRDB, with explicit migrations and one collection-writing authority, instead of using live Markdown/JSON files or framework-managed object persistence. This concentrates atomic saves, independent completion/archive state, ordering, consistent export and recoverable snapshots behind the Collection Store interface, at the cost of maintaining a schema and a database dependency.

Markdown plus a metadata manifest and task JSON are portable exports, not a second live store. Use SQLite-consistent snapshots and a fresh safety snapshot before generation-based replacement; never copy a live main database file without accounting for WAL. Unsaved captures never enter persistent storage. See the [model and recovery design](../technical-design.md); no database has been created or recovery behavior verified yet.

Implementation status, 2026-10-13: #24 created the first Collection Store (notes only) on GRDB 7.11.1 with the system SQLite; see the [Collection Store foundation section](../technical-design.md#collection-store-foundation--issue-24). Snapshots, export and restore remain unimplemented.
