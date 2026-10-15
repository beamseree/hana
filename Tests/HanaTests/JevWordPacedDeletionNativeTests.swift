import AppKit
import Testing
@testable import Hana

/// Real editor commands with a fixture Store and controlled Jev. These tests
/// establish command delivery and UTF-16 selection, not physical focus.
@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct JevWordPacedDeletionNativeTests {
    private let insertion = NSRange(location: NSNotFound, length: 0)

    enum Deletion: CaseIterable, Sendable {
        case character, word, line
        var modifiers: NSEvent.ModifierFlags {
            switch self { case .character: []; case .word: .option; case .line: .command }
        }
        var remainingText: String {
            switch self {
            case .character: "call mom tomorrow บ้า"
            case .word: "call mom tomorrow "
            case .line: ""
            }
        }
    }

    @Test(arguments: Deletion.allCases)
    func nativeDeletionHoldsApplicableAnswersAndPreservesTextAndSelection(deletion: Deletion) async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = HeldJev()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { fake.finishAll(); interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()

        type("call mom ", into: editor)
        try await eventually { fake.inputs == ["call mom"] }
        editor.insertText("tomorrow บ้าน", replacementRange: insertion)
        editor.keyDown(with: try deleteKey(deletion.modifiers))
        let expected = deletion.remainingText
        let selection = NSRange(location: (expected as NSString).length, length: 0)
        #expect(interaction.mode == .search && editor.string == expected)
        #expect(editor.selectedRange() == selection)
        #expect(fake.inputs.count == 1)

        fake.reply(.task)
        try await Task.sleep(for: .milliseconds(30))
        #expect(interaction.mode == .search && editor.string == expected)
        #expect(editor.selectedRange() == selection && fake.inputs.count == 1)
        if deletion == .line {
            // Clear cancels even an HTTP request that ignores cancellation,
            // and the next text is a fresh session of switching.
            type("buy milk ", into: editor)
            try await eventually { fake.inputs.count == 2 }
            fake.reply(.note)
            try await eventually { interaction.mode == .note }
            #expect(editor.string == "buy milk ")
        } else {
            try await eventually { interaction.mode == .task }
            #expect(editor.string == expected && editor.selectedRange() == selection)
        }
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.isEmpty && records.tasks.isEmpty)
        await store.close()
    }

    @Test func enterImmediatelyAfterDeletingUsesSearchAndALateAnswerCannotStealIt() async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = HeldJev()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { fake.finishAll(); interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()

        type("call mom ", into: editor)
        try await eventually { fake.inputs == ["call mom"] }
        editor.insertText("tomorrow บ้าน", replacementRange: insertion)
        editor.keyDown(with: try deleteKey([]))
        let expected = "call mom tomorrow บ้า"
        let selection = NSRange(location: (expected as NSString).length, length: 0)
        #expect(interaction.mode == .search && editor.string == expected)
        try #require(interaction.selectedRow == .suggestion(.note))
        editor.keyDown(with: try returnKey())
        fake.reply(.task)
        try await eventually { interaction.mode == .note }
        try await Task.sleep(for: .milliseconds(200))
        #expect(interaction.mode == .note && editor.string == expected)
        #expect(editor.selectedRange() == selection && interaction.currentInvocation == invocation)
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.isEmpty && records.tasks.isEmpty)
        await store.close()
    }

    @Test func replacingASelectionThatLooksLikeAnAppendStillHoldsTheAnswer() async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = HeldJev()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { fake.finishAll(); interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()

        type("call mo", into: editor)
        try await eventually { fake.inputs == ["call mo"] }
        editor.setSelectedRange(NSRange(location: 5, length: 2))
        editor.insertText("mom บ้าน", replacementRange: insertion)
        let expected = "call mom บ้าน"
        let selection = NSRange(location: (expected as NSString).length, length: 0)
        #expect(editor.string == expected && editor.selectedRange() == selection)
        fake.reply(.task)
        try await Task.sleep(for: .milliseconds(30))
        #expect(interaction.mode == .search && fake.inputs.count == 1)
        try await eventually { interaction.mode == .task }
        #expect(editor.string == expected && editor.selectedRange() == selection)
        await store.close()
    }

    private func type(_ text: String, into editor: NSTextView) {
        for character in text { editor.insertText(String(character), replacementRange: insertion) }
    }
    private func editor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.title == "Hana Search" && NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
    private func deleteKey(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
    }

    /// Like a sent HTTP request, this fake may finish after cancellation.
    @MainActor private final class HeldJev: Classifier {
        private(set) var inputs: [String] = []
        private var pending: [CheckedContinuation<ClassifierVerdict, Never>] = []
        func classify(_ text: String) async throws -> ClassifierVerdict {
            inputs.append(text)
            return await withCheckedContinuation { pending.append($0) }
        }
        func reply(_ label: ClassifierVerdict.Label) {
            guard !pending.isEmpty else { return }
            pending.removeFirst().resume(returning: .init(label: label, probabilities: [label: 0.95]))
        }
        func finishAll() { while !pending.isEmpty { reply(.search) } }
    }

}
