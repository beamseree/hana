import AppKit
import Observation
import SwiftUI

/// Window identity is independent of the section it presents.
enum WorkingWindow: Hashable {
    case main
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

/// Values shared by the native window, SwiftUI and Mac Interaction's callers.
/// No editor or database handle is exposed by the presentation.
@MainActor @Observable
final class MainWindowPresentation {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let title: String
        let isPinned: Bool

        init(_ note: Note) {
            id = note.id
            title = note.title ?? "Untitled"
            isPinned = note.isPinned
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

    private(set) var selectedSection: MainSection = .notes
    private(set) var rows: [Row] = []
    private(set) var availability: Availability = .loading

    func select(_ section: MainSection) { selectedSection = section }

    fileprivate func receive(_ notes: [Note]) {
        rows = notes.map(Row.init)
        availability = .available
    }

    fileprivate func unavailable(_ reason: UnavailableReason) {
        rows = []
        availability = .unavailable(reason)
    }
}

@MainActor
final class WorkingWindowController: NSWindowController {
    let presentation = MainWindowPresentation()
    private var observation: Task<Void, Never>?

    init(collection: Task<CollectionStore, any Error>?) {
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
        window.contentView = NSHostingView(rootView: MainWindowView(presentation: presentation))
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

    func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    deinit { observation?.cancel() }
    required init?(coder: NSCoder) { fatalError("Use init(collection:)") }
}

private struct MainWindowView: View {
    let presentation: MainWindowPresentation

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<MainSection?>(
                get: { presentation.selectedSection },
                set: { if let section = $0 { presentation.select(section) } }
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
            if presentation.selectedSection != .notes {
                message(presentation.selectedSection.rawValue, detail: "This section is coming soon.")
            } else if presentation.rows.isEmpty {
                message("No notes yet", detail: "Capture a note from the search bar to see it here.")
            } else {
                List(presentation.rows) { row in
                    HStack(spacing: 8) {
                        if row.isPinned {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(Color(nsColor: HanaColor.Icon.secondary))
                                .accessibilityLabel("Pinned")
                        }
                        Text(row.title).lineLimit(1).help(row.title)
                    }
                    .accessibilityElement(children: .combine)
                    .listRowBackground(Color(nsColor: HanaColor.Surface.group))
                }
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Notes")
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
