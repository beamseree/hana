import AppKit
import Observation
import SwiftUI

/// Committed Archive records retain their kind, including in selection identity.
@MainActor @Observable
final class ArchiveWorkspacePresentation {
    enum Availability: Equatable { case loading, available, unavailable }
    enum Row: Identifiable, Equatable {
        enum ID: Hashable { case note(UUID), task(UUID) }
        case note(Note), task(TaskItem)

        var id: ID {
            switch self { case .note(let note): .note(note.id); case .task(let task): .task(task.id) }
        }
        var title: String {
            switch self { case .note(let note): note.title ?? "Untitled"; case .task(let task): task.title }
        }
        var kindLabel: String { switch self { case .note: "Note"; case .task: "Task" } }
        var completionLabel: String? {
            switch self { case .note: nil; case .task(let task): task.completedAt == nil ? "Unfinished" : "Completed" }
        }
        var archivedAt: Date? {
            switch self { case .note(let note): note.archivedAt; case .task(let task): task.archivedAt }
        }
        fileprivate var tieKey: String {
            switch self { case .note(let note): "note-\(note.id.uuidString)"; case .task(let task): "task-\(task.id.uuidString)" }
        }
    }

    private(set) var rows: [Row] = []
    var selectedID: Row.ID?
    var selectedRow: Row? { rows.first { $0.id == selectedID } }
    private(set) var notice: String?
    private(set) var isRestoring = false
    private let collection: Task<CollectionStore, any Error>?
    private let organizeNote: @MainActor (MainWindowPresentation.Row, MainNoteAction) async throws -> Void
    private(set) var availability: Availability = .loading
    private var notes: [Note] = []
    private var tasks: [TaskItem] = []
    private var loadedNotes = false
    private var loadedTasks = false
    private var observations: [Task<Void, Never>] = []

    init(collection: Task<CollectionStore, any Error>?,
         organizeNote: @escaping @MainActor (MainWindowPresentation.Row, MainNoteAction) async throws -> Void) {
        self.collection = collection
        self.organizeNote = organizeNote
        guard let collection else { availability = .unavailable; return }
        observations.append(Task { [weak self] in
            do {
                let store = try await collection.value
                for try await notes in store.observe(.archivedNotes, in: store.generation) {
                    guard !Task.isCancelled else { return }
                    self?.notes = notes
                    self?.loadedNotes = true
                    self?.receive()
                }
            } catch { if !Task.isCancelled { self?.unavailable() } }
        })
        observations.append(Task { [weak self] in
            do {
                let store = try await collection.value
                for try await tasks in store.observe(.archivedTasks, in: store.generation) {
                    guard !Task.isCancelled else { return }
                    self?.tasks = tasks
                    self?.loadedTasks = true
                    self?.receive()
                }
            } catch { if !Task.isCancelled { self?.unavailable() } }
        })
    }

    func canRestore(_ row: Row) -> Bool {
        availability == .available && !isRestoring && rows.contains { $0.id == row.id }
    }

    @discardableResult
    func restore(_ row: Row) async -> Bool {
        guard canRestore(row), let collection else { return false }
        isRestoring = true
        defer { isRestoring = false }
        do {
            switch row {
            case .note(let note): try await organizeNote(MainWindowPresentation.Row(note), .restore)
            case .task(let task):
                let store = try await collection.value
                _ = try await store.perform(.restoreTask(task.id, expectedRevision: task.revision), in: store.generation)
            }
            notice = nil
            return true
        } catch {
            notice = error as? CollectionStoreError == .staleRevision
                ? "This item changed. Review the current Archive before trying again."
                : "The restore couldn’t be confirmed. Your item is still in the collection; review it before trying again."
            return false
        }
    }

    private func receive() {
        guard availability != .unavailable, loadedNotes && loadedTasks else { return }
        rows = (notes.map(Row.note) + tasks.map(Row.task)).sorted {
            if $0.archivedAt != $1.archivedAt { return ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
            return $0.tieKey < $1.tieKey
        }
        if !rows.contains(where: { $0.id == selectedID }) { selectedID = nil }
        availability = .available
    }

    private func unavailable() { rows = []; selectedID = nil; availability = .unavailable }
    func stopObserving() { observations.forEach { $0.cancel() }; observations = [] }
    isolated deinit { observations.forEach { $0.cancel() } }
}

struct ArchiveWorkspaceView: View {
    let archive: ArchiveWorkspacePresentation
    let openNote: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = archive.notice {
                Text(notice).foregroundStyle(Color(nsColor: HanaColor.Status.error))
                    .accessibilityLabel("Archive action: \(notice)")
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch archive.availability {
        case .loading: ProgressView("Opening Archive…")
        case .unavailable:
            Text("Archive is unavailable. Close and reopen Hana to try again.")
                .foregroundStyle(Color(nsColor: HanaColor.Text.secondary))
        case .available:
            if archive.rows.isEmpty {
                Text("Nothing is archived.").foregroundStyle(Color(nsColor: HanaColor.Text.secondary))
            } else {
                List(archive.rows, selection: Binding(get: { archive.selectedID }, set: { archive.selectedID = $0 })) { row in
                    HStack(spacing: 8) {
                        Text(row.title).lineLimit(1).help(row.title).frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.kindLabel).font(HanaFont.detail.font)
                        if let completion = row.completionLabel { Text(completion).font(HanaFont.detail.font) }
                        Button("Restore") { Task { await archive.restore(row) } }
                            .disabled(!archive.canRestore(row))
                            .accessibilityLabel("Restore \(row.title)")
                    }
                    .tag(row.id)
                    .onTapGesture(count: 2) { if case .note(let note) = row { openNote(note.id) } }
                    .contextMenu {
                        if case .note(let note) = row { Button("Open Note") { openNote(note.id) } }
                        Button("Restore") { Task { await archive.restore(row) } }.disabled(!archive.canRestore(row))
                    }
                    .accessibilityElement(children: .combine)
                    .listRowBackground(Color(nsColor: HanaColor.Surface.group))
                }
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Archive")
                .onKeyPress(.return) {
                    guard case .note(let note) = archive.selectedRow else { return .ignored }
                    openNote(note.id)
                    return .handled
                }
            }
        }
    }
}
