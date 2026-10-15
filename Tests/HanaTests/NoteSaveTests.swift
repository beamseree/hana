import AppKit
import Synchronization
import Testing
@testable import Hana

/// Saving a Note capture through the real editor into a real temporary Store.
/// Fixture roots only: nothing here can reach the live collection.
@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct NoteSaveTests {
    private let none = NSRange(location: NSNotFound, length: 0)

    @Test func enterCommitsExactlyOneNoteAndClosesAfterTheConfirmation() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store }, confirmationDuration: .milliseconds(300))
        let invocation = interaction.presentBar()
        let editor = try await firstResponderEditor()
        let body = "  # Groceries บันทึก  \n\n- [ ] milk *2*\r\n\t"
        editor.insertText("-", replacementRange: none)
        editor.insertText(body, replacementRange: none)
        editor.keyDown(with: try returnKey())

        try await eventually { interaction.modeLabelText == "Saved" }
        // The confirmation shows in the bar; keystrokes during it never reach the capture.
        #expect(interaction.currentInvocation == invocation)
        editor.insertText("late", replacementRange: none)
        editor.keyDown(with: try returnKey())
        #expect(editor.string == body)
        try await eventually { interaction.currentInvocation == nil }

        let notes = try await store.read(.notes, in: store.generation)
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(Array(note.body.utf8) == Array(body.utf8))
        #expect(note.title == "# Groceries บันทึก")
        await store.close()

        // The note survives closing and reopening the Store from the same root.
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.notes, in: reopened.generation) == [note])
        await reopened.close()
    }

    @Test func repeatedEnterWhileTheSaveIsPausedCommitsExactlyOneNote() async throws {
        let fixture = try TemporaryFixture()
        let gate = CommitGate()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in gate.pass() }))
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store }, confirmationDuration: .zero)
        _ = interaction.presentBar()
        let editor = try await firstResponderEditor()
        editor.insertText("-", replacementRange: none)
        editor.insertText("once", replacementRange: none)
        editor.keyDown(with: try returnKey())
        try await eventually { gate.arrivals == 1 }
        for _ in 0..<3 { editor.keyDown(with: try returnKey()) }
        editor.insertText(" more", replacementRange: none)
        #expect(editor.string == "once")
        gate.open()
        try await eventually { interaction.currentInvocation == nil }
        #expect(gate.arrivals == 1)
        let notes = try await store.read(.notes, in: store.generation)
        #expect(notes.map(\.body) == ["once"])
        await store.close()
    }

    @Test func enterDuringCompositionCommitsItWithoutSaving() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("-", replacementRange: none)
        editor.insertText("note ", replacementRange: none)
        editor.setMarkedText("ไท", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(interaction.currentInvocation == invocation && interaction.modeLabelText == "Note")
        #expect(try await store.read(.notes, in: store.generation).isEmpty)
        await store.close()
    }

    @Test(arguments: ["", "  \n\t\u{2028} "])
    func aWhitespaceOnlyNoteIsRefusedWithoutReachingTheStore(text: String) async throws {
        let fixture = try TemporaryFixture()
        let commands = Mutex(0)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            commands.withLock { $0 += 1 }
        }))
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("-", replacementRange: none)
        if !text.isEmpty { editor.insertText(text, replacementRange: none) }
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.captureMessage != nil }
        #expect(interaction.captureMessage == "Write something to save this note.")
        #expect(interaction.mode == .note && editor.string == text)
        #expect(interaction.currentInvocation == invocation)
        try await Task.sleep(for: .milliseconds(50))
        #expect(commands.withLock { $0 } == 0)
        #expect(try await store.read(.notes, in: store.generation).isEmpty)
        // Writing something clears the explanation.
        editor.insertText("x", replacementRange: none)
        #expect(interaction.captureMessage == nil)
        await store.close()
    }

    @Test(arguments: [MacInteraction.DismissalReason.escape, .outsideClick])
    func dismissingBeforeASaveWritesNothing(reason: MacInteraction.DismissalReason) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let before = try await store.read(.allRecords, in: store.generation)
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store })
        let invocation = interaction.presentBar()
        let editor = try await firstResponderEditor()
        editor.insertText("-", replacementRange: none)
        editor.insertText("unsaved thought", replacementRange: none)
        if reason == .escape { editor.keyDown(with: try escapeKey()) } else { interaction.dismiss(invocation, reason: reason) }
        #expect(interaction.currentInvocation == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await store.read(.allRecords, in: store.generation) == before)

        let next = interaction.presentBar()
        defer { interaction.dismiss(next, reason: .outsideClick) }
        #expect(interaction.mode == .search && interaction.query == "")
        editor.insertText("-", replacementRange: none)
        #expect(interaction.mode == .note && editor.string == "")
        await store.close()
    }

    @Test func aFailureBeforeCommitKeepsTheTextAndModeWithAnExplanation() async throws {
        struct Injected: Error {}
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in throw Injected() }))
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("-", replacementRange: none)
        editor.insertText("keep\nme", replacementRange: none)
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.captureMessage != nil }
        #expect(interaction.captureMessage == "Save not confirmed. Your text is kept. Press Enter to retry.")
        #expect(interaction.mode == .note && interaction.modeLabelText == "Note")
        #expect(editor.string == "keep\nme" && interaction.currentInvocation == invocation)
        #expect(editor.window?.firstResponder === editor)
        // The text stays editable.
        editor.insertText("!", replacementRange: none)
        #expect(editor.string == "keep\nme!")
        #expect(try await store.read(.notes, in: store.generation).isEmpty)
        await store.close()
    }

    @Test func whenTheStoreCannotOpenSearchStillWorksAndCaptureExplainsAndKeepsTheText() async throws {
        let fixture = try TemporaryFixture()
        // Another instance holds the owner lock.
        let owner = try await CollectionStore.open(fixture.location)
        let location = fixture.location
        let feed = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero),
                                         collection: Task { try await CollectionStore.open(location) })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("milk", replacementRange: none)
        await feed.send([app("Milk", "/fixture/Milk.app")])
        try await eventually { interaction.results.map(\.name) == ["Milk"] }

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("-", replacementRange: none)
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.captureMessage != nil }
        #expect(interaction.captureMessage == "The collection couldn’t be opened, so notes can’t be saved right now. Your text is kept.")
        #expect(interaction.mode == .note && editor.string == "milk")
        #expect(interaction.currentInvocation == invocation)
        #expect(try await owner.read(.notes, in: owner.generation).isEmpty)
        await owner.close()
    }

    @Test func withoutACollectionCaptureExplainsAndKeepsTheText() async throws {
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("-", replacementRange: none)
        editor.insertText("note", replacementRange: none)
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.captureMessage != nil }
        #expect(interaction.captureMessage == "The collection couldn’t be opened, so notes can’t be saved right now. Your text is kept.")
        #expect(editor.string == "note")
    }

    @Test func returningToSearchLeavesTheNoteNoticeBehind() async throws {
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("-", replacementRange: none)
        editor.insertText("note", replacementRange: none)
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.captureMessage != nil }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .search && editor.string == "note")
        #expect(interaction.captureMessage == nil)
    }

    @Test func diagnosticsNeverRecordCapturedText() async throws {
        let fixture = try TemporaryFixture()
        let log = fixture.directory.appendingPathComponent("diagnostics.jsonl")
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(diagnostics: Diagnostics(file: log),
                                         search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store }, confirmationDuration: .zero)
        _ = interaction.presentBar()
        let editor = try await firstResponderEditor()
        let secret = "zq-private-capture-7731"
        editor.insertText("-", replacementRange: none)
        editor.insertText("   ", replacementRange: none)
        editor.keyDown(with: try returnKey())
        editor.insertText(secret, replacementRange: none)
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.currentInvocation == nil }
        let recorded = try String(contentsOf: log, encoding: .utf8)
        #expect(recorded.contains("capture.saved"))
        #expect(!recorded.contains("zq-private") && !recorded.contains("7731"))
        await store.close()
    }

    /// The owned origin is a key panel of this process holding a text field's
    /// editor. The test runner never runs the app's event loop, so it can't be
    /// activated; it is reported as frontmost instead, as it is in the app when
    /// one of its windows has focus.
    @Test(arguments: [MacInteraction.DismissalReason.saved, .escape])
    func anOwnedOriginWindowGetsItsKeyStatusAndResponderBack(reason: MacInteraction.DismissalReason) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store }, confirmationDuration: .zero,
                                         frontmostApplication: { .current })
        let origin = OwnedOrigin()
        defer { origin.panel.close() }
        origin.panel.makeKeyAndOrderFront(nil)
        #expect(origin.panel.makeFirstResponder(origin.field))
        try await eventually { NSApp.keyWindow === origin.panel }
        let responder = try #require(origin.panel.firstResponder)
        #expect(responder !== origin.panel)

        let invocation = interaction.presentBar()
        try await eventually { NSApp.keyWindow !== origin.panel && NSApp.keyWindow?.firstResponder is NSTextView }
        let editor = try await firstResponderEditor()
        #expect(!origin.panel.isKeyWindow)
        editor.insertText("-", replacementRange: none)
        editor.insertText("from an owned window", replacementRange: none)
        editor.keyDown(with: try reason == .saved ? returnKey() : escapeKey())
        try await eventually { interaction.currentInvocation == nil }
        #expect(invocation != interaction.currentInvocation)
        #expect(origin.panel.isKeyWindow)
        #expect(origin.panel.firstResponder === responder)
        #expect(try await store.read(.notes, in: store.generation).count == (reason == .saved ? 1 : 0))
        await store.close()
    }

    private func firstResponderEditor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
}

@MainActor
private final class OwnedOrigin {
    let panel = KeyPanel(contentRect: NSRect(x: 200, y: 200, width: 320, height: 80),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 280, height: 24))

    init() {
        panel.title = "Owned origin"
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView?.addSubview(field)
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
func returnKey(shift: Bool = false) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                  characters: "\r", charactersIgnoringModifiers: "\r",
                                  isARepeat: false, keyCode: 36))
}

@MainActor
func backspaceKey() throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                  characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                  isARepeat: false, keyCode: 51))
}

@MainActor
func escapeKey() throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                  characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                  isARepeat: false, keyCode: 53))
}

/// Holds the Store's writer inside the save's transaction until opened.
final class CommitGate: Sendable {
    private let state = Mutex((arrivals: 0, isOpen: false))
    private let semaphore = DispatchSemaphore(value: 0)
    var arrivals: Int { state.withLock { $0.arrivals } }

    func pass() {
        let wait = state.withLock { state in
            state.arrivals += 1
            return !state.isOpen
        }
        if wait { semaphore.wait() }
    }

    func open() {
        state.withLock { $0.isOpen = true }
        semaphore.signal()
    }
}
