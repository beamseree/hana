import Foundation

/// Stable, synthetic fixture identities. The owner-only sidecar is published
/// after seeding; an interrupted/missing seed is refused, never reseeded.
struct WorkingWindowsFixture: Codable, Sendable, Equatable {
    static let sidecarName = "working-windows-seed.json"
    static let quitBody = "Fixture — Quit/relaunch\nType the physical persistence marker below this line.\n"
    static let smokeBody = quitBody + "hana99-normal-quit-ไทย🌸\n"
    let version: Int
    let notes: [String: UUID]
    let tasks: [String: UUID]

    static func open(root: URL) async throws -> (CollectionStore, Self) {
        guard root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else { throw WorkingWindowsOptions.Failure.fixture }
        let existing = FileManager.default.fileExists(atPath: root.path)
        let location = try existing ? CollectionLocation.fixture(root) : CollectionLocation.createFixtureRoot(at: root)
        let sidecar = root.appendingPathComponent(sidecarName)
        let seed: Self?
        if existing {
            var metadata = stat()
            guard lstat(sidecar.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else { throw WorkingWindowsOptions.Failure.fixture }
            seed = try JSONDecoder().decode(Self.self, from: Data(contentsOf: sidecar))
            guard seed?.version == 1, Set(seed?.notes.values.map { $0 } ?? []).count == 6,
                  Set(seed?.tasks.values.map { $0 } ?? []).count == 10, Set(seed?.notes.keys.map { $0 } ?? []) == ["scratch", "preview", "long", "quit", "archived", "archivedPinned"],
                  Set(seed?.tasks.keys.map { $0 } ?? []) == ["inbox1", "inbox2", "inbox3", "today1", "today2", "today3", "completed1", "completed2", "archivedOpen", "archivedDone"] else { throw WorkingWindowsOptions.Failure.fixture }
        } else { seed = nil }
        let store = try await CollectionStore.open(location)
        do {
            if let seed {
                for id in seed.notes.values { guard try await store.read(.note(id), in: store.generation) != nil else { throw WorkingWindowsOptions.Failure.fixture } }
                for id in seed.tasks.values { guard try await store.read(.task(id), in: store.generation) != nil else { throw WorkingWindowsOptions.Failure.fixture } }
                return (store, seed)
            }
            var notes: [String: UUID] = [:]
            var tasks: [String: UUID] = [:]
            let bodies = [
                ("scratch", "Fixture — Scratch\nภาษาไทย 🌸\nUse this note for typing, paste, selection and undo."),
                ("preview", "Fixture — Preview\n\n# Markdown ไทย🌸\n\n**Strong**, *emphasis* and [Example](https://example.com).\n\n- One\n- Two\n\n> Quote\n\n```swift\nlet flower = \"🌸\"\n```\n\n![literal image](https://example.invalid/image.png)\n\n<div>literal HTML</div>"),
                ("long", "Fixture — Long note\n" + String(repeating: "ภาษาไทย 🌸 — sustained typing and scrolling.\n", count: 20_000)),
                ("quit", quitBody),
                ("archived", "Fixture — Archived note\nRead-only until restored."),
                ("archivedPinned", "Fixture — Archived pinned note\nPin survives restore.")
            ]
            for (alias, body) in bodies {
                var note = try await store.perform(.createNote(operation: UUID(), body: body), in: store.generation)
                notes[alias] = note.id
                if alias == "scratch" || alias == "archivedPinned" { note = try await store.perform(.setNotePinned(note.id, true, expectedRevision: note.revision), in: store.generation) }
                if alias.hasPrefix("archived") { _ = try await store.perform(.archiveNote(note.id, expectedRevision: note.revision), in: store.generation) }
            }
            for alias in ["inbox1", "inbox2", "inbox3", "today1", "today2", "today3", "completed1", "completed2", "archivedOpen", "archivedDone"] {
                let placement: TaskPlacement = alias.hasPrefix("today") ? .today : .inbox
                var task = try await store.perform(.createTask(operation: UUID(), title: "Fixture — \(alias)", placement: placement), in: store.generation)
                tasks[alias] = task.id
                if alias.hasPrefix("completed") || alias == "archivedDone" { task = try await store.perform(.completeTask(task.id, expectedRevision: task.revision), in: store.generation) }
                if alias.hasPrefix("archived") { _ = try await store.perform(.archiveTask(task.id, expectedRevision: task.revision), in: store.generation) }
            }
            let seeded = Self(version: 1, notes: notes, tasks: tasks)
            try JSONEncoder().encode(seeded).write(to: sidecar, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
            return (store, seeded)
        } catch {
            await store.close()
            throw error
        }
    }
}
