import Foundation
@testable import Hana

/// A synthetic collection covering every organization fact, for export and
/// snapshot comparisons: pins, archived notes, duplicate and unsafe-looking
/// titles, Unicode, manual Inbox/Today order and every task
/// completion/archive combination. Contains no personal content.
enum OrganizedCollection {
    struct Contents: Equatable {
        let notes: [Note]
        let tasks: [TaskItem]
    }

    static let noteBodies = [
        "Plain note",
        "Pinned\nwith a second line",
        "Same title\nfirst copy",
        "Same title\nsecond copy",
        "../../etc/passwd\nnot a path",
        "CON\nreserved device name",
        "a/b\\c:d*?\"<>|\nfilename punctuation",
        ".hidden\ndot first",
        "\n\n   \nLate title after blank lines",
        "Thai บันทึก é (e\u{301}) 🌸\r\n# Markdown *kept*\u{2028}tail\0end  ",
        "Archived and pinned",
        "Archived plain",
    ]

    static let taskTitles = [
        "Inbox one", "Inbox two", "Inbox three",
        "Today one", "Today two",
        "Completed from Inbox", "Completed from Today",
        "Archived unfinished", "Archived completed", "Restored completed",
        "../../tasks.json", "งาน Thai 🌸 é (e\u{301})",
    ]

    /// Populates an empty store, advancing `clock` between commands so every
    /// timestamp differs. Returns the committed contents.
    @discardableResult
    static func populate(_ store: CollectionStore, clock: FixedClock) async throws -> Contents {
        let g = store.generation
        func tick() { clock.advance(by: 1.25) }
        var notes: [String: Note] = [:]
        for body in noteBodies {
            notes[body] = try await store.perform(.createNote(operation: UUID(), body: body), in: g)
            tick()
        }
        _ = try await store.perform(.setNotePinned(notes["Pinned\nwith a second line"]!.id, true, expectedRevision: 1), in: g)
        tick()
        let archivedPinned = notes["Archived and pinned"]!
        _ = try await store.perform(.setNotePinned(archivedPinned.id, true, expectedRevision: 1), in: g)
        _ = try await store.perform(.archiveNote(archivedPinned.id, expectedRevision: 2), in: g)
        tick()
        _ = try await store.perform(.archiveNote(notes["Archived plain"]!.id, expectedRevision: 1), in: g)
        tick()
        _ = try await store.perform(.editNote(notes["Plain note"]!.id, expectedRevision: 1, body: "Plain note, edited"), in: g)
        tick()

        var tasks: [String: TaskItem] = [:]
        for title in taskTitles {
            let placement: TaskPlacement = title.hasPrefix("Today") || title == "Completed from Today" ? .today : .inbox
            tasks[title] = try await store.perform(.createTask(operation: UUID(), title: title, placement: placement), in: g)
            tick()
        }
        func current(_ title: String) async throws -> TaskItem {
            try await store.read(.task(tasks[title]!.id), in: g)!
        }
        for title in ["Completed from Inbox", "Completed from Today", "Archived completed", "Restored completed"] {
            _ = try await store.perform(.completeTask(tasks[title]!.id, expectedRevision: 1), in: g)
            tick()
        }
        for title in ["Archived unfinished", "Archived completed", "Restored completed"] {
            let task = try await current(title)
            _ = try await store.perform(.archiveTask(task.id, expectedRevision: task.revision), in: g)
            tick()
        }
        let restore = try await current("Restored completed")
        _ = try await store.perform(.restoreTask(restore.id, expectedRevision: restore.revision), in: g)
        tick()
        // Manual order differing from creation order in both lists.
        for placement in TaskPlacement.allCases {
            let list = try await store.read(.tasks(in: placement), in: g)
            guard let last = list.last, list.count > 1 else { continue }
            _ = try await store.perform(.reorderTask(last.id, expectedRevision: last.revision, in: placement,
                                                     expectedOrder: list.map(\.id), toIndex: 0), in: g)
            tick()
        }
        return try await read(store)
    }

    static func read(_ store: CollectionStore) async throws -> Contents {
        Contents(notes: try await store.read(.allNotes, in: store.generation),
                 tasks: try await store.read(.allTasks, in: store.generation))
    }
}
