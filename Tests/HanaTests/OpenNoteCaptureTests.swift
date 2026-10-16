import AppKit
import Testing
@testable import Hana

struct OpenNoteCaptureSessionTests {
    @Test func openInWindowSubmitsTheExactNoteOnceAndRetriesTheSameReceipt() {
        var session = captureFixture("-", text: "# ไทย 🌸\n**Markdown**  \n")
        let operation = session.operation
        let effect = CaptureSession.Effect.saveNoteInWindow(operation: operation, body: "# ไทย 🌸\n**Markdown**  \n")
        #expect(session.handle(.openInWindow) == [effect])
        #expect(session.state.phase == .saving)
        #expect(session.handle(.openInWindow).isEmpty)
        #expect(session.handle(.submit).isEmpty)
        #expect(session.handle(.insert("lost", replacing: session.state.selection, provenance: .typed)) == [.consumeInsertion])
        _ = session.handle(.saveFailed(.failed))
        #expect(session.state.text == "# ไทย 🌸\n**Markdown**  \n" && session.state.mode == .note)
        #expect(session.handle(.openInWindow) == [effect])
        #expect(session.operation == operation)
    }

    @Test(arguments: ["", " \n\t\u{2028}"])
    func blankNotesAreRefusedWithoutASaveEffect(text: String) {
        var session = captureFixture("-", text: text)
        #expect(session.handle(.openInWindow).isEmpty)
        #expect(session.state.notice == .blank && session.state.phase == .editing)
        #expect(session.state.text == text && session.state.mode == .note)
    }

    @Test func searchAndTaskNeverSubmitAnOpenNote() {
        var search = CaptureSession()
        _ = search.handle(.edited(text: "query", selection: NSRange(location: 5, length: 0)))
        #expect(search.handle(.openInWindow).isEmpty)
        var task = captureFixture("[", text: "Title")
        #expect(task.handle(.openInWindow).isEmpty)
        #expect(task.state.phase == .editing && task.state.mode == .task)
    }

    @Test func explicitOpeningRetryAfterADismissedFailureOwnsTheNewAttempt() {
        var session = captureFixture("-")
        let first = session.handle(.openInWindow)
        _ = session.handle(.dismissed)
        #expect(session.state.dismissalRequested)
        _ = session.handle(.saveFailed(.failed))
        #expect(session.handle(.openInWindow) == first)
        #expect(!session.state.dismissalRequested)
        #expect(session.handle(.saved) == [.confirmSaved])
    }

}

@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct OpenNoteCaptureTests {
    private let none = NSRange(location: NSNotFound, length: 0)

    @Test func pausedRepeatedOpeningCommitsOnceAndFocusesTheSavedNotesEnd() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        defer { gate.open() }
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in gate.pass() }))
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        let invocation = interaction.presentBar()
        let editor = try await captureEditor()
        editor.insertText("-", replacementRange: none)
        editor.insertText("ไทย 🌸\n**text**", replacementRange: none)
        interaction.openCaptureInWindow()
        try await eventually { gate.arrivals == 1 }
        for _ in 0..<3 { interaction.openCaptureInWindow(); editor.keyDown(with: try returnKey()) }
        editor.insertText("late", replacementRange: none)
        #expect(editor.string == "ไทย 🌸\n**text**" && !editor.isEditable)
        #expect(interaction.currentInvocation == invocation)
        gate.open()
        try await eventually { interaction.currentInvocation == nil }
        let notes = try await store.read(.notes, in: store.generation)
        #expect(notes.count == 1)
        let saved = try #require(notes.first)
        #expect(saved.body == "ไทย 🌸\n**text**")
        try await eventually { interaction.window(for: .note(saved.id))?.firstResponder is NSTextView }
        let window = try #require(interaction.window(for: .note(saved.id)))
        let noteEditor = try #require(window.firstResponder as? NSTextView)
        #expect(noteEditor.string == saved.body)
        #expect(noteEditor.selectedRange() == NSRange(location: 15, length: 0))
        #expect(gate.arrivals == 1)
        await store.close()
        window.close()
    }

    @Test func noteControlAndCommandReturnSubmitThroughTheSameIntent() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        let invocation = interaction.presentBar()
        let editor = try await captureEditor()
        #expect(interaction.openInWindowButton.isHidden)
        editor.insertText("-", replacementRange: none)
        #expect(!interaction.openInWindowButton.isHidden)
        NSApp.sendAction(try #require(interaction.openInWindowButton.action), to: interaction.openInWindowButton.target, from: interaction.openInWindowButton)
        #expect(interaction.captureMessage == "Write something to save this note.")
        #expect(interaction.currentInvocation == invocation)
        #expect(editor.window?.firstResponder === editor)
        editor.insertText("Continue here", replacementRange: none)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.window?.windowNumber ?? 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        #expect(editor.window?.performKeyEquivalent(with: key) == true)
        try await eventually { interaction.currentInvocation == nil }
        let notes = try await store.read(.notes, in: store.generation)
        #expect(notes.map(\.body) == ["Continue here"])
        let note = try #require(notes.first)
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        await store.close()
        interaction.window(for: .note(note.id))?.close()
    }

    @Test(arguments: [false, true])
    func failureKeepsTheCaptureAndRetryOpensExactlyOneNote(lostAcknowledgement: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fail = FailOnce()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if !lostAcknowledgement, fail.take() { throw InjectedFailure() }
        }, afterCommit: {
            if lostAcknowledgement, fail.take() { throw InjectedFailure() }
        }))
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        let invocation = interaction.presentBar()
        let editor = try await captureEditor()
        editor.insertText("-", replacementRange: none)
        editor.insertText("Keep the note ไทย", replacementRange: none)
        interaction.openCaptureInWindow()
        try await eventually { interaction.captureMessage != nil }
        #expect(interaction.currentInvocation == invocation && interaction.mode == .note)
        #expect(editor.string == "Keep the note ไทย" && editor.isEditable)
        let first = try await store.read(.notes, in: store.generation)
        #expect(first.count == (lostAcknowledgement ? 1 : 0))
        interaction.openCaptureInWindow()
        try await eventually { interaction.currentInvocation == nil }
        let notes = try await store.read(.notes, in: store.generation)
        #expect(notes.map(\.body) == ["Keep the note ไทย"])
        if let firstID = first.first?.id { #expect(notes.first?.id == firstID) }
        let note = try #require(notes.first)
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        await store.close()
        interaction.window(for: .note(note.id))?.close()
    }

    @Test func aNewerInvocationKeepsFocusWhenAnEarlierNoteOpeningFinishes() async throws {
        try await NativeAppFixture.run(.openNoteCapture, requiring: "open-note-capture.newer-bar")
    }


    @Test func compositionKeepsTheOpenControlDisabledAndSavesNothing() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        _ = interaction.presentBar()
        let editor = try await captureEditor()
        editor.insertText("-", replacementRange: none)
        editor.setMarkedText("ไท", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        #expect(!interaction.openInWindowButton.isEnabled)
        interaction.openCaptureInWindow()
        #expect(try await store.read(.notes, in: store.generation).isEmpty)
        #expect(editor.hasMarkedText() && interaction.mode == .note)
        editor.insertText("ไทย", replacementRange: none)
        #expect(interaction.openInWindowButton.isEnabled)
        #expect(editor.string == "ไทย")
        await store.close()
    }

    @Test func dismissalDuringACommittedOpeningKeepsTheUsersNewDestination() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        defer { gate.open() }
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in gate.pass() }))
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        let invocation = interaction.presentBar()
        let editor = try await captureEditor()
        editor.insertText("-", replacementRange: none)
        editor.insertText("Saved quietly", replacementRange: none)
        interaction.openCaptureInWindow()
        try await eventually { gate.arrivals == 1 }
        interaction.dismiss(invocation, reason: .outsideClick)
        #expect(interaction.presentBar() == invocation)
        gate.open()
        try await eventually { interaction.currentInvocation == nil }
        let notes = try await store.read(.notes, in: store.generation)
        #expect(notes.map(\.body) == ["Saved quietly"])
        let note = try #require(notes.first)
        #expect(interaction.window(for: .note(note.id)) == nil)
        await store.close()
    }

    private func captureEditor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.title == "Hana Search" && NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
}
