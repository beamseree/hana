# Portable collection export v1

Issue #28 implements the bounded full-export portion of #22 through `CollectionRecovery.export(from:in:to:)`. It reads `allRecords` once, then releases the database read before serialization. Later commands may commit while that immutable value is written. `validateExport(at:)` inspects the package; it does not import or replace a collection.

## Package

```text
Hana-export-<new UUID>/
  manifest.json
  tasks.json
  notes/<note UUID>.md
```

The JSON documents have `formatVersion: 1`. IDs are UUID strings; generated filenames use uppercase UUIDs, never titles. All dates are signed 64-bit UTC Unix milliseconds, matching Store precision. Revisions and order keys are signed 64-bit integers; consumers must preserve them without converting through a floating-point JSON number. Optional facts are omitted when absent. SHA-256 values are lowercase hexadecimal over the exact file bytes.

`manifest.json` contains:

- `collectionID`, `noteCount`, `taskCount`, `tasksSHA256`.
- `captureMethod: "single-committed-store-read"`, `captureStartedAt`, `captureFinishedAt`, `packagedAt`.
- `notes`: ID, relative `path`, derived `title`, `sha256`, `byteCount`, `createdAt`, `contentEditedAt`, `updatedAt`, `revision`, `pinned`, optional `archivedAt`.

The capture timestamps bracket the Store read. They are wall-clock observations, not a database commit timestamp or monotonically increasing transaction ID; the system clock can change. `packagedAt` records package assembly separately. Collection identity plus this provenance describes the captured collection without inventing a global Store revision.

Each note file holds its exact UTF-8 body, including line endings, whitespace and Unicode normalization. `tasks.json` contains `formatVersion`, the same `collectionID`, and `tasks`: ID, exact `title`, `createdAt`, `contentEditedAt`, `updatedAt`, `revision`, optional `completedAt`, `archivedAt`, `placement`, and `orderKey`. Completion and archive are independent. Placement is `inbox` or `today`, present together with order only for unarchived unfinished tasks.

All records are serialized in ID order. Organization is reconstructed using the existing domain rules: active Notes pinned first then descending content-edit time and ID; active task lists by ascending order key and ID; Completed and Archive by their respective descending timestamps and ID. The independent test decoder uses only this wire format and compares every record and organized query view.

## Publication and validation

The destination must be an existing directory on a local filesystem. Source Store root and default personal root, their descendants and resolved aliases are refused. A fresh owner-only `.hana-export-<UUID>.partial` directory is created inside the destination, keeping staging and publication on the same volume. Files are exclusively created with mode 0600, written, synchronized and closed; directories use 0700. The complete staged package is re-read and validated before macOS exclusive rename publishes its fresh final name. Existing destinations are never overwritten. Unsupported exclusive-rename behavior is an explicit publication failure, with no copy/delete fallback.

Validation checks versions, collection IDs, unique IDs, fixed UUID-derived paths, regular files (not symlinks), expected package entries, counts, hashes, UTF-8, nonblank notes, derived titles, positive revisions, single-line nonblank task titles, and independent completion/archive/placement/order invariants. Public validation rejects the reserved staging namespace. Checksums detect accidental payload corruption; they are not authentication against an attacker who rewrites both data and checksums.

Failures distinguish invalid package/version, refused/unsupported destination, readonly filesystem, no space/quota, write errno and publication errno. A failed attempt is never returned as complete. Cleanup removes this attempt's staging directory on an ordinary error; a process crash can leave a hidden staging directory, which is not a published export. Earlier packages remain untouched. This is not a power-loss or hostile-filesystem guarantee.

## Caller and harness contracts

A future real-note editor must successfully flush pending edits before calling export. A failed flush must stop export. There is no editor, draft persistence, general import, snapshot replacement, schedule or retention in this ticket. Portable domain content excludes creation receipts, external app/file references, usage history and unsaved buffers.

The fixture harness adds:

```text
Hana --collection-fixture export <source-root> --destination <destination-root>
Hana --collection-fixture validate-export <destination-root> --package Hana-export-<UUID>
```

Both roots must already have the disposable marker; validation accepts only a direct package child. Events contain package basename, collection ID and counts, never note/task text. Normal app launch is unchanged and does not initialize personal storage.
