import AppKit
import Synchronization
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct NoteSaveSafetyNativeTests {
    @Test func failureStatusOffersCopyAndRetryOfTheLatestNativeText() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fail = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if fail.withLock({ $0 }) { throw CollectionStoreError.storageFailure(code: 13) }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        _ = interaction.open(.main)
        _ = interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let editor = try #require(interaction.window(for: .note(note.id))?.firstResponder as? NSTextView)
        fail.withLock { $0 = true }
        editor.selectAll(nil)
        editor.insertText("First ไทย", replacementRange: NSRange(location: NSNotFound, length: 0))
        await #expect(throws: CollectionStoreError.storageFailure(code: 13)) { try await interaction.noteSession(note.id)?.flush() }
        try await eventually { interaction.noteSaveStatus(note.id)?.contains("disk is full") == true }
        #expect(interaction.noteActions(note.id) == [.retry, .copyText])
        await withRestoredPasteboard {
            await interaction.performNoteAction(.copyText, id: note.id)
            #expect(NSPasteboard.general.string(forType: .string) == "First ไทย")
        }
        editor.insertText(" latest", replacementRange: NSRange(location: NSNotFound, length: 0))
        fail.withLock { $0 = false }
        await interaction.performNoteAction(.retry, id: note.id)
        try await eventually { interaction.noteSaveStatus(note.id) == "Saved" }
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == "First ไทย latest")
        #expect(try await store.read(.note(note.id), in: store.generation)?.revision == 2)
        await store.close()
    }
    @Test(arguments: [NoteSaveAction.retry, .discardChanges])
    func failedCloseIsHeldUntilRetryOrExplicitDiscard(action: NoteSaveAction) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fail = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if fail.withLock({ $0 }) { throw CollectionStoreError.storageFailure(code: 8) }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        _ = interaction.open(.main)
        _ = interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let window = try #require(interaction.window(for: .note(note.id)))
        let editor = try #require(window.firstResponder as? NSTextView)
        fail.withLock { $0 = true }
        editor.selectAll(nil)
        editor.insertText("Keep this unsaved text", replacementRange: NSRange(location: NSNotFound, length: 0))
        await #expect(throws: CollectionStoreError.storageFailure(code: 8)) { try await interaction.noteSession(note.id)?.flush() }
        window.performClose(nil)
        try await eventually { interaction.noteCloseIsHeld(note.id) && window.attachedSheet != nil }
        #expect(interaction.window(for: .note(note.id)) === window)
        #expect(interaction.noteActions(note.id) == [.retry, .copyText, .discardChanges])
        await withRestoredPasteboard {
            await interaction.performNoteAction(.copyText, id: note.id)
            #expect(NSPasteboard.general.string(forType: .string) == "Keep this unsaved text")
            #expect(interaction.window(for: .note(note.id)) === window)
        }
        if action == .retry { fail.withLock { $0 = false } }
        await interaction.performNoteAction(action, id: note.id)
        try await eventually { interaction.window(for: .note(note.id)) == nil }
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == (action == .retry ? "Keep this unsaved text" : "Original"))
        await store.close()
    }

    @Test func quitCancelsOnFailureThenCommitsEveryNoteAndCompositionBeforeClosingTheStore() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fail = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if fail.withLock({ $0 }) { throw CollectionStoreError.storageFailure(code: 13) }
        }))
        let first = try await store.perform(.createNote(operation: UUID(), body: "First"), in: store.generation)
        let second = try await store.perform(.createNote(operation: UUID(), body: "Second"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer {
            interaction.window(for: .note(first.id))?.close()
            interaction.window(for: .note(second.id))?.close()
            interaction.stop()
        }
        _ = interaction.open(.main)
        _ = interaction.open(.note(first.id))
        try await eventually { interaction.window(for: .note(first.id))?.firstResponder is NSTextView }
        let firstEditor = try #require(interaction.window(for: .note(first.id))?.firstResponder as? NSTextView)
        fail.withLock { $0 = true }
        firstEditor.setSelectedRange(NSRange(location: firstEditor.string.utf16.count, length: 0))
        firstEditor.insertText(" edited", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = interaction.open(.note(second.id))
        try await eventually { interaction.window(for: .note(second.id))?.firstResponder is NSTextView }
        let secondEditor = try #require(interaction.window(for: .note(second.id))?.firstResponder as? NSTextView)
        secondEditor.setSelectedRange(NSRange(location: secondEditor.string.utf16.count, length: 0))
        secondEditor.setMarkedText(" ไทย", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(secondEditor.hasMarkedText())
        #expect(await interaction.prepareForQuit() == false)
        #expect(!secondEditor.hasMarkedText())
        #expect(firstEditor.isEditable && secondEditor.isEditable)
        #expect(interaction.noteSession(first.id)?.canRetry == true)
        #expect(interaction.noteSession(second.id)?.canRetry == true)
        #expect(interaction.noteCloseIsHeld(first.id) || interaction.noteCloseIsHeld(second.id))
        #expect(try await store.read(.notes, in: store.generation).count == 2)
        fail.withLock { $0 = false }
        #expect(await interaction.prepareForQuit())
        await #expect(throws: CollectionStoreError.closed) { _ = try await store.read(.notes, in: store.generation) }
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(Set(try await reopened.read(.notes, in: reopened.generation).map(\.body)) == ["First edited", "Second ไทย"])
        await reopened.close()
    }

    @Test func aPausedQuitFreezesAlreadyFlushedTextAndBlocksNewWindowsAndBar() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let enabled = Mutex(false)
        let commits = Mutex(0)
        let gate = CommitGate()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if enabled.withLock({ $0 }) {
                let count = commits.withLock { value in value += 1; return value }
                if count == 2 { gate.pass() }
            }
        }))
        let first = try await store.perform(.createNote(operation: UUID(), body: "First"), in: store.generation)
        let second = try await store.perform(.createNote(operation: UUID(), body: "Second"), in: store.generation)
        let unopened = try await store.perform(.createNote(operation: UUID(), body: "Unopened"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer {
            gate.open()
            for note in [first, second, unopened] { interaction.window(for: .note(note.id))?.close() }
            interaction.stop()
        }
        _ = interaction.open(.main)
        var editors: [NSTextView] = []
        for note in [first, second] {
            _ = interaction.open(.note(note.id))
            try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
            let editor = try #require(interaction.window(for: .note(note.id))?.firstResponder as? NSTextView)
            editors.append(editor)
        }
        for editor in editors {
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText(" edited", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        enabled.withLock { $0 = true }
        let quitting = Task { await interaction.prepareForQuit() }
        try await eventually { gate.arrivals == 1 }
        let sessions = [first, second].compactMap { interaction.noteSession($0.id) }
        let flushed = try #require(sessions.first(where: { $0.state == .saved }))
        let body = flushed.text
        #expect(editors.allSatisfy { !$0.isEditable })
        for editor in editors { editor.insertText(" LATE", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        flushed.edit("LATE direct event")
        #expect(flushed.text == body)
        #expect(editors.map(\.string) == ["First edited", "Second edited"])
        #expect(!interaction.open(.note(unopened.id)))
        _ = interaction.presentBar()
        #expect(interaction.currentInvocation == nil)
        gate.open()
        #expect(await quitting.value)
        #expect(!interaction.open(.note(unopened.id)))
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(Set(try await reopened.read(.notes, in: reopened.generation).map(\.body)) == ["First edited", "Second edited", "Unopened"])
        await reopened.close()
    }

    @Test(arguments: [false, true])
    func pendingCloseOffersChoicesAndDiscardCancelsItsUncommittedText(discard: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let enabled = Mutex(false)
        let gate = CommitGate()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if enabled.withLock({ $0 }) { gate.pass() }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { gate.open(); interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        _ = interaction.open(.main)
        _ = interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let window = try #require(interaction.window(for: .note(note.id)))
        let editor = try #require(window.firstResponder as? NSTextView)
        enabled.withLock { $0 = true }
        editor.selectAll(nil)
        editor.insertText("Pending close", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.performClose(nil)
        try await eventually { gate.arrivals == 1 && interaction.noteCloseIsHeld(note.id) && window.attachedSheet != nil }
        try await eventually { interaction.noteSaveStatus(note.id) == "Saving…" }
        #expect(interaction.noteActions(note.id) == [.retry, .copyText, .discardChanges])
        #expect(NSApp.activationPolicy() == .regular)
        if discard { await interaction.performNoteAction(.discardChanges, id: note.id) }
        gate.open()
        try await eventually { interaction.window(for: .note(note.id)) == nil }
        await store.close()
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.note(note.id), in: reopened.generation)?.body == (discard ? "Original" : "Pending close"))
        await reopened.close()
    }

    @Test func invalidatedDirtyEditorKeepsCopyableTextAndCannotApproveQuit() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        _ = interaction.open(.main)
        _ = interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let editor = try #require(interaction.window(for: .note(note.id))?.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("Unsaved before invalidation", replacementRange: NSRange(location: NSNotFound, length: 0))
        await store.close()
        try await eventually { !editor.isEditable && interaction.noteSaveStatus(note.id)?.contains("no longer available") == true }
        editor.insertText(" late", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "Unsaved before invalidation")
        #expect(await interaction.prepareForQuit() == false)
        await withRestoredPasteboard {
            await interaction.performNoteAction(.copyText, id: note.id)
            #expect(NSPasteboard.general.string(forType: .string) == "Unsaved before invalidation")
        }
        await interaction.performNoteAction(.discardChanges, id: note.id)
        #expect(await interaction.prepareForQuit())
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.note(note.id), in: reopened.generation)?.body == "Original")
        await reopened.close()
    }

    @Test(arguments: [false, true])
    func quitWaitsForAnAlreadySubmittedCaptureAndRetainsItIfTheSaveFails(fails: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fail = Mutex(fails)
        let gate = CommitGate()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            gate.pass()
            if fail.withLock({ $0 }) { throw CollectionStoreError.storageFailure(code: 13) }
        }))
        let interaction = MacInteraction(collection: Task { store }, confirmationDuration: .zero,
                                         frontmostApplication: { .current })
        defer { gate.open(); interaction.stop() }
        _ = interaction.open(.main)
        _ = interaction.presentBar()
        // The CLT helper cannot activate as a regular app. Drive the visible
        // bar's actual first responder, as note tests do for their own window;
        // physical key focus belongs to the app-loop and #99 checks.
        try await eventually { NSApp.windows.contains { $0.title == "Hana Search" && $0.isVisible && $0.firstResponder is NSTextView } }
        let bar = try #require(NSApp.windows.first { $0.title == "Hana Search" && $0.isVisible })
        let editor = try #require(bar.firstResponder as? NSTextView)
        let none = NSRange(location: NSNotFound, length: 0)
        editor.insertText("-", replacementRange: none)
        editor.insertText("Submitted capture ไทย", replacementRange: none)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await eventually { gate.arrivals == 1 }
        var result: Bool?
        var started = false
        let quit = Task { started = true; result = await interaction.prepareForQuit() }
        try await eventually { started }
        #expect(result == nil)
        #expect(!interaction.open(.main))
        gate.open()
        await quit.value
        #expect(result == !fails)
        if fails {
            #expect(interaction.currentInvocation != nil)
            #expect(editor.string == "Submitted capture ไทย")
            #expect(editor.isEditable)
            #expect(try await store.read(.notes, in: store.generation).isEmpty)
            fail.withLock { $0 = false }
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            #expect(await interaction.prepareForQuit())
        }
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.notes, in: reopened.generation).map(\.body) == ["Submitted capture ไทย"])
        await reopened.close()
    }

}

@MainActor
private func withRestoredPasteboard(_ body: () async throws -> Void) async rethrows {
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { source in
        let item = NSPasteboardItem()
        for type in source.types { if let data = source.data(forType: type) { item.setData(data, forType: type) } }
        return item
    }
    defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
    try await body()
}
