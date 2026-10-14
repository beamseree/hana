import CryptoKit
import Foundation
import Testing
@testable import Hana

/// Test-only reconstruction from the documented portable wire format. Shares
/// no Recovery DTO, decoder, date conversion, hash or validation code.
enum IndependentExportDecoder {
    static func records(at package: URL) throws -> CollectionRecords {
        let manifest = try object(package.appendingPathComponent("manifest.json"))
        #expect(try value(manifest, "formatVersion", Int.self) == 1)
        let collectionID = try uuid(manifest, "collectionID")
        let tasksData = try Data(contentsOf: package.appendingPathComponent("tasks.json"))
        #expect(digest(tasksData) == (try value(manifest, "tasksSHA256", String.self)))
        let document = try object(package.appendingPathComponent("tasks.json"))
        #expect(try value(document, "formatVersion", Int.self) == 1)
        #expect(try uuid(document, "collectionID") == collectionID)
        let notes = try value(manifest, "notes", [[String: Any]].self).map { row in
            let id = try uuid(row, "id")
            let path = try value(row, "path", String.self)
            #expect(path == "notes/\(id.uuidString).md")
            let data = try Data(contentsOf: package.appendingPathComponent(path))
            #expect(data.count == (try value(row, "byteCount", Int.self)))
            #expect(digest(data) == (try value(row, "sha256", String.self)))
            let body = try #require(String(data: data, encoding: .utf8))
            return Note(id: id, body: body, createdAt: try date(row, "createdAt"),
                        contentEditedAt: try date(row, "contentEditedAt"), updatedAt: try date(row, "updatedAt"),
                        revision: try value(row, "revision", Int64.self), isPinned: try value(row, "pinned", Bool.self),
                        archivedAt: try optionalDate(row, "archivedAt"))
        }
        let tasks = try value(document, "tasks", [[String: Any]].self).map { row in
            TaskItem(id: try uuid(row, "id"), title: try value(row, "title", String.self),
                     createdAt: try date(row, "createdAt"), contentEditedAt: try date(row, "contentEditedAt"),
                     updatedAt: try date(row, "updatedAt"), revision: try value(row, "revision", Int64.self),
                     completedAt: try optionalDate(row, "completedAt"), archivedAt: try optionalDate(row, "archivedAt"),
                     placement: (row["placement"] as? String).flatMap(TaskPlacement.init(rawValue:)), orderKey: row["orderKey"] as? Int64)
        }
        #expect(try value(manifest, "noteCount", Int.self) == notes.count)
        #expect(try value(manifest, "taskCount", Int.self) == tasks.count)
        return CollectionRecords(collectionID: collectionID, notes: notes.sorted { $0.id.uuidString < $1.id.uuidString },
                                 tasks: tasks.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    static func views(_ records: CollectionRecords) -> OrganizedCollection.Views {
        func tasks(_ placement: TaskPlacement) -> [TaskItem] {
            records.tasks.filter { $0.placement == placement }.sorted {
                if $0.orderKey != $1.orderKey { return $0.orderKey! < $1.orderKey! }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        return .init(records: records, notes: records.notes.filter { $0.archivedAt == nil }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.contentEditedAt != $1.contentEditedAt { return $0.contentEditedAt > $1.contentEditedAt }
            return $0.id.uuidString < $1.id.uuidString
        }, archivedNotes: records.notes.filter { $0.archivedAt != nil }.sorted {
            if $0.archivedAt != $1.archivedAt { return $0.archivedAt! > $1.archivedAt! }
            return $0.id.uuidString < $1.id.uuidString
        }, inbox: tasks(.inbox), today: tasks(.today), completed: records.tasks.filter {
            $0.completedAt != nil && $0.archivedAt == nil
        }.sorted {
            if $0.completedAt != $1.completedAt { return $0.completedAt! > $1.completedAt! }
            return $0.id.uuidString < $1.id.uuidString
        }, archivedTasks: records.tasks.filter { $0.archivedAt != nil }.sorted {
            if $0.archivedAt != $1.archivedAt { return $0.archivedAt! > $1.archivedAt! }
            return $0.id.uuidString < $1.id.uuidString
        })
    }

    private static func object(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    private static func value<T>(_ row: [String: Any], _ key: String, _: T.Type) throws -> T {
        try #require(row[key] as? T)
    }
    private static func uuid(_ row: [String: Any], _ key: String) throws -> UUID {
        try #require(UUID(uuidString: value(row, key, String.self)))
    }
    private static func date(_ row: [String: Any], _ key: String) throws -> Date {
        Date(timeIntervalSince1970: Double(try value(row, key, Int64.self)) / 1000)
    }
    private static func optionalDate(_ row: [String: Any], _ key: String) throws -> Date? {
        guard row[key] != nil, !(row[key] is NSNull) else { return nil }
        return try date(row, key)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
