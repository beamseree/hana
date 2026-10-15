import AppKit
import Observation
import SwiftUI

/// Window identity is independent of the section it presents.
enum WorkingWindow: Hashable {
    case main
    case note(UUID)
}

enum MainSection: String, CaseIterable, Identifiable {
    case notes = "Notes", inbox = "Inbox", today = "Today", completed = "Completed", archive = "Archive"
    var id: Self { self }

    var symbol: String {
        switch self {
        case .notes: "note.text"
        case .inbox: "tray"
        case .today: "sun.max"
        case .completed: "checkmark.circle"
        case .archive: "archivebox"
        }
    }
}

typealias MainNoteAction = NoteOrganizationAction

/// Values shared by the native window, SwiftUI and Mac Interaction's callers.
/// No editor or database handle is exposed by the presentation.
@MainActor @Observable
final class MainWindowPresentation {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let title: String
        let isPinned: Bool
        let revision: Int64

        init(_ note: Note) {
            id = note.id
            title = note.title ?? "Untitled"
            isPinned = note.isPinned
            revision = note.revision
        }
    }

    enum UnavailableReason: Equatable {
        case noCollection
        case openingFailed
        case observationFailed(CollectionStoreError?)

        var message: String {
            switch self {
            case .noCollection: "The collection is unavailable in this run."
            case .openingFailed: "The collection couldn’t be opened. Your saved notes are unavailable."
            case .observationFailed: "The collection is no longer available. Close and reopen Hana to try again."
            }
        }
    }

    enum Availability: Equatable {
        case loading, available, unavailable(UnavailableReason)
    }

    enum NoteNotice: Equatable {
        case refused(CollectionStoreError)
        case unavailable
        case compositionActive

        var message: String {
            switch self {
            case .refused(.staleRevision): "This note changed. Review its latest version and try again."
            case .refused(.archivedNote): "This note was archived. Restore it before changing it."
            case .refused(.noteNotFound): "This note is no longer available."
            case .refused: "The note couldn’t be changed. Try again."
            case .unavailable: "The collection is unavailable. The note wasn’t changed."
            case .compositionActive: "Finish composing text before organizing this note."
            }
        }
    }

    private(set) var selectedSection: MainSection = .notes
    var selectedNoteID: UUID?
    private(set) var rows: [Row] = []
    private(set) var availability: Availability = .loading
    fileprivate(set) var noteNotice: NoteNotice?
    fileprivate(set) var isOrganizingNote = false

    func select(_ section: MainSection) { selectedSection = section }

    fileprivate func receive(_ notes: [Note]) {
        rows = notes.map(Row.init)
        if !rows.contains(where: { $0.id == selectedNoteID }) { selectedNoteID = nil }
        availability = .available
    }

    fileprivate func unavailable(_ reason: UnavailableReason) {
        rows = []
        selectedNoteID = nil
        availability = .unavailable(reason)
    }
}

@MainActor
final class WorkingWindowController: NSWindowController {
    let presentation = MainWindowPresentation()
    var openNote: ((UUID) -> Void)?
    let taskWorkspace: TaskWorkspacePresentation
    let archiveWorkspace: ArchiveWorkspacePresentation
    private var observation: Task<Void, Never>?
    private var sectionSelection: Task<Void, Never>?
    private var closePreparation: Task<Void, Never>?
    var closeIsHeld: Bool { closePreparation != nil }
    private let organizeAction: @MainActor (MainWindowPresentation.Row, MainNoteAction) async throws -> Void

    init(collection: Task<CollectionStore, any Error>?,
         organizeNote: @escaping @MainActor (MainWindowPresentation.Row, MainNoteAction) async throws -> Void) {
        taskWorkspace = TaskWorkspacePresentation(collection: collection)
        archiveWorkspace = ArchiveWorkspacePresentation(collection: collection, organizeNote: organizeNote)
        organizeAction = organizeNote
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "Hana"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 360)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = HanaColor.Surface.window
        window.contentView = NSHostingView(rootView: MainWindowView(
            presentation: presentation,
            openNote: { [weak self] id in self?.openNote?(id) },
            tasks: taskWorkspace,
            archive: archiveWorkspace,
            selectSection: { [weak self] section in self?.selectSection(section) },
            organizeNote: { [weak self] row, action in await self?.organizeNote(row, action: action) }
        ))
        window.center()
        guard let collection else {
            presentation.unavailable(.noCollection)
            return
        }
        observation = Task { [weak presentation] in
            let store: CollectionStore
            do { store = try await collection.value }
            catch {
                if !Task.isCancelled { presentation?.unavailable(.openingFailed) }
                return
            }
            guard !Task.isCancelled else { return }
            do {
                for try await notes in store.observe(.notes, in: store.generation) {
                    guard !Task.isCancelled else { return }
                    presentation?.receive(notes)
                }
            } catch {
                guard !Task.isCancelled else { return }
                presentation?.unavailable(.observationFailed(error as? CollectionStoreError))
            }
        }
    }

    func selectSection(_ section: MainSection) {
        sectionSelection?.cancel()
        guard section != presentation.selectedSection else { return }
        guard taskWorkspace.editing != nil else { presentation.select(section); return }
        sectionSelection = Task { [weak self] in
            guard let self, await taskWorkspace.commitRename(), !Task.isCancelled else { return }
            presentation.select(section)
        }
    }

    func shouldClose() -> Bool {
        guard taskWorkspace.editing != nil else { return true }
        guard closePreparation == nil else { return false }
        closePreparation = Task { [weak self] in
            guard let self else { return }
            defer { closePreparation = nil }
            guard await taskWorkspace.commitRename(), !Task.isCancelled else { return }
            window?.close()
        }
        return false
    }

    func stopObserving() {
        closePreparation?.cancel()
        sectionSelection?.cancel()
        taskWorkspace.stopObserving()
        archiveWorkspace.stopObserving()
        observation?.cancel()
        observation = nil
    }

    func organizeNote(_ row: MainWindowPresentation.Row, action: MainNoteAction) async {
        guard !presentation.isOrganizingNote else { return }
        presentation.isOrganizingNote = true
        defer { presentation.isOrganizingNote = false }
        presentation.noteNotice = nil
        do {
            try await organizeAction(row, action)
        } catch {
            if error as? NoteOrganizationError == .compositionActive { presentation.noteNotice = .compositionActive }
            else {
                presentation.noteNotice = (error as? CollectionStoreError).map(MainWindowPresentation.NoteNotice.refused)
                    ?? .unavailable
            }
        }
    }

    deinit { observation?.cancel() }
    required init?(coder: NSCoder) { fatalError("Use init(collection:)") }
}

private struct MainWindowView: View {
    let presentation: MainWindowPresentation
    let openNote: (UUID) -> Void
    let tasks: TaskWorkspacePresentation
    let archive: ArchiveWorkspacePresentation
    let selectSection: (MainSection) -> Void
    let organizeNote: @MainActor (MainWindowPresentation.Row, MainNoteAction) async -> Void

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<MainSection?>(
                get: { presentation.selectedSection },
                set: { if let section = $0 { selectSection(section) } }
            )) {
                ForEach(MainSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 240)
            .accessibilityLabel("Sections")
        } detail: {
            VStack(alignment: .leading, spacing: 16) {
                Text(presentation.selectedSection.rawValue)
                    .font(HanaFont.Heading.window.font)
                    .tracking(HanaFont.Heading.window.kern)
                content
                if presentation.selectedSection == .notes, let notice = presentation.noteNotice {
                    Text(notice.message)
                        .foregroundStyle(Color(nsColor: HanaColor.Text.secondary))
                        .accessibilityLabel("Note action: \(notice.message)")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: HanaColor.Surface.window))
        }
        .font(HanaFont.body.font)
        .foregroundStyle(Color(nsColor: HanaColor.Text.primary))
        .tint(Color(nsColor: HanaColor.Focus.ring))
    }

    @ViewBuilder private var content: some View {
        switch presentation.availability {
        case .loading:
            ProgressView("Opening collection…")
        case .unavailable(let reason):
            message("Collection unavailable", detail: reason.message)
        case .available:
            if presentation.selectedSection == .inbox || presentation.selectedSection == .today || presentation.selectedSection == .completed {
                TaskWorkspaceView(tasks: tasks, section: presentation.selectedSection)
            } else if presentation.selectedSection == .archive {
                ArchiveWorkspaceView(archive: archive, openNote: openNote)
            } else if presentation.rows.isEmpty {
                message("No notes yet", detail: "Capture a note from the search bar to see it here.")
            } else {
                List(presentation.rows, selection: Binding(
                    get: { presentation.selectedNoteID }, set: { presentation.selectedNoteID = $0 }
                )) { row in
                    HStack(spacing: 8) {
                        if row.isPinned {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(Color(nsColor: HanaColor.Icon.secondary))
                                .accessibilityLabel("Pinned")
                        }
                        Text(row.title).lineLimit(1).help(row.title)
                    }
                    .tag(row.id)
                    .onTapGesture(count: 2) { openNote(row.id) }
                    .contextMenu {
                        Button(row.isPinned ? "Unpin Note" : "Pin Note") {
                            Task { await organizeNote(row, .setPinned(!row.isPinned)) }
                        }
                        Button("Archive Note") {
                            Task { await organizeNote(row, .archive) }
                        }
                    }
                    .disabled(presentation.isOrganizingNote)
                    .accessibilityElement(children: .combine)
                    .listRowBackground(Color(nsColor: HanaColor.Surface.group))
                }
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Notes")
                .onKeyPress(.return) {
                    guard let id = presentation.selectedNoteID else { return .ignored }
                    openNote(id)
                    return .handled
                }
            }
        }
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(HanaFont.label.font)
            Text(detail).foregroundStyle(Color(nsColor: HanaColor.Text.secondary))
        }
    }
}
