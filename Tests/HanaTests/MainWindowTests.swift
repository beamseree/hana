import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct MainWindowTests {
    @Test func notesShowCommittedStoreOrderAndUpdateWhileOpen() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let pinned = try await store.perform(.createNote(operation: UUID(), body: "\n  Pinned\nbody"), in: g)
        clock.advance(by: 1)
        let recent = try await store.perform(.createNote(operation: UUID(), body: "Recent"), in: g)
        let archived = try await store.perform(.createNote(operation: UUID(), body: "Archived"), in: g)
        _ = try await store.perform(.setNotePinned(pinned.id, true, expectedRevision: 1), in: g)
        _ = try await store.perform(.archiveNote(archived.id, expectedRevision: 1), in: g)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        #expect(interaction.open(.main))
        try await eventually { interaction.mainWindowPresentation?.rows.map(\.id) == [pinned.id, recent.id] }
        #expect(interaction.mainWindowPresentation?.rows.map(\.title) == ["Pinned", "Recent"])
        clock.advance(by: 1)
        let new = try await store.perform(.createNote(operation: UUID(), body: "New"), in: g)
        try await eventually { interaction.mainWindowPresentation?.rows.map(\.id) == [pinned.id, new.id, recent.id] }
        await store.close()
        try await eventually { interaction.mainWindowPresentation?.availability == .unavailable(.observationFailed(.closed)) }
        #expect(interaction.mainWindowPresentation?.rows.isEmpty == true)
    }

    @Test(arguments: [false, true])
    func collectionUnavailableIsDistinctFromAnEmptyCollection(openingFails: Bool) async throws {
        _ = NSApplication.shared
        let collection: Task<CollectionStore, any Error>? = openingFails
            ? Task { throw CollectionStoreError.unreadableCollection } : nil
        let interaction = MacInteraction(collection: collection)
        defer { interaction.stop() }
        interaction.open(.main, section: .today)
        let expected: MainWindowPresentation.UnavailableReason = openingFails ? .openingFailed : .noCollection
        try await eventually { interaction.mainWindowPresentation?.availability == .unavailable(expected) }
        #expect(interaction.mainWindowPresentation?.selectedSection == .today)
        #expect(interaction.mainWindowPresentation?.rows.isEmpty == true)
        let window = try #require(interaction.window(for: .main))
        #expect(!containsEditableControl(window.contentView))
    }

    @Test func reopeningReusesMainWindowAndMinimizedMembershipKeepsRegularPolicy() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(collection: Task { store })
        interaction.open(.main)
        let window = try #require(interaction.window(for: .main))
        defer { interaction.stop() }
        try await eventually { interaction.mainWindowPresentation?.availability == .available }
        #expect(interaction.mainWindowPresentation?.rows.isEmpty == true)
        interaction.open(.main, section: .archive)
        #expect(interaction.window(for: .main) === window)
        #expect(interaction.mainWindowPresentation?.selectedSection == .archive)
        interaction.open(.main)
        #expect(interaction.mainWindowPresentation?.selectedSection == .archive)
        #expect(NSApp.activationPolicy() == .regular)
        window.miniaturize(nil)
        try await eventually { window.isMiniaturized }
        #expect(NSApp.activationPolicy() == .regular)
        interaction.open(.main, section: .notes)
        try await eventually { !window.isMiniaturized }
        #expect(interaction.mainWindowPresentation?.selectedSection == .notes)
        window.close()
        #expect(interaction.mainWindowPresentation == nil)
        #expect(NSApp.activationPolicy() == .accessory)
        interaction.open(.main)
        try await eventually { interaction.mainWindowPresentation?.availability == .available }
        await store.close()
    }

    @Test func menusOpenTheSameMainWindowWithoutMockDestinations() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(collection: Task { store })
        let previousMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        interaction.start()
        defer {
            interaction.stop()
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        let menu = try #require(NSApp.windowsMenu)
        let index = menu.indexOfItem(withTitle: "Open Hana")
        #expect(index >= 0)
        menu.performActionForItem(at: index)
        let window = try #require(interaction.window(for: .main))
        let statusMenu = try #require(interaction.menuBarMenu)
        #expect(statusMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Search", statusMenu.items[1].title, "Open Hana", "Quit Hana"])
        statusMenu.performActionForItem(at: statusMenu.indexOfItem(withTitle: "Open Hana"))
        let delegate = AppDelegate(interaction: interaction)
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        menu.performActionForItem(at: index)
        #expect(interaction.window(for: .main) === window)
        #expect(!menu.items.contains { $0.title.localizedCaseInsensitiveContains("validation") || $0.title.contains("Mock") })
        await store.close()
    }
}

@MainActor
private func containsEditableControl(_ view: NSView?) -> Bool {
    guard let view else { return false }
    if let text = view as? NSTextView, text.isEditable { return true }
    if let field = view as? NSTextField, field.isEditable { return true }
    return view.subviews.contains { containsEditableControl($0) }
}
