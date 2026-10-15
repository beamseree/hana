import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct TaskWorkspaceTests {
    @Test func activeListsObserveStoreOrderAndNewTasksAtTheTop() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let first = try await store.perform(.createTask(operation: UUID(), title: "First"), in: store.generation)
        let second = try await store.perform(.createTask(operation: UUID(), title: "Second"), in: store.generation)
        let today = try await store.perform(.createTask(operation: UUID(), title: "Today", placement: .today), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == [second.id, first.id] }
        #expect(interaction.taskWorkspacePresentation?.today.map(\.id) == [today.id])
        let captured = try await store.perform(.createTask(operation: UUID(), title: "Captured"), in: store.generation)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == [captured.id, second.id, first.id] }
        await store.close()
        try await eventually { interaction.taskWorkspacePresentation?.availability == .unavailable }
        #expect(interaction.taskWorkspacePresentation?.inbox.isEmpty == true)
    }
    @Test func taskActionsCommitStoreTransitionsAndObserveBothLists() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let original = try await store.perform(.createTask(operation: UUID(), title: "Move me"), in: store.generation)
        let existing = try await store.perform(.createTask(operation: UUID(), title: "Already Today", placement: .today), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.count == 1 }
        interaction.selectTask(original.id)
        #expect(await interaction.performTaskAction(.moveToToday))
        try await eventually { interaction.taskWorkspacePresentation?.today.map(\.id) == [original.id, existing.id] }
        #expect(interaction.taskWorkspacePresentation?.inbox.isEmpty == true)
        interaction.open(.main, section: .today)
        interaction.selectTask(original.id)
        #expect(await interaction.performTaskAction(.moveToInbox))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == [original.id] }
        interaction.open(.main, section: .inbox)
        interaction.selectTask(original.id)
        #expect(await interaction.performTaskAction(.complete))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.isEmpty == true }
        let completed = try #require(try await store.read(.task(original.id), in: store.generation))
        #expect(completed.completedAt != nil && completed.placement == nil && completed.orderKey == nil)
        #expect(completed.createdAt == original.createdAt)
        interaction.open(.main, section: .today)
        interaction.selectTask(existing.id)
        #expect(await interaction.performTaskAction(.archive))
        try await eventually { interaction.taskWorkspacePresentation?.today.isEmpty == true }
        let archived = try #require(try await store.read(.task(existing.id), in: store.generation))
        #expect(archived.archivedAt != nil && archived.completedAt == nil && archived.placement == nil)
        await store.close()
    }

    @Test func renameKeepsInvalidDraftAndReloadsStaleCommittedTitle() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let original = try await store.perform(.createTask(operation: UUID(), title: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.count == 1 }
        interaction.selectTask(original.id)
        #expect(await interaction.performTaskAction(.rename))
        interaction.editTaskTitle("  ")
        #expect(await interaction.commitTaskRename() == false)
        #expect(interaction.taskWorkspacePresentation?.editing?.text == "  ")
        #expect(interaction.taskWorkspacePresentation?.notice != nil)
        interaction.editTaskTitle("one\ntwo")
        #expect(await interaction.commitTaskRename() == false)
        #expect(interaction.taskWorkspacePresentation?.editing?.text == "one\ntwo")
        let unchanged = try await store.read(.task(original.id), in: store.generation)
        #expect(unchanged == original)
        interaction.editTaskTitle("My draft")
        let concurrent = try await store.perform(.editTaskTitle(original.id, expectedRevision: 1, title: "Changed elsewhere"), in: store.generation)
        #expect(await interaction.commitTaskRename() == false)
        #expect(interaction.taskWorkspacePresentation?.editing?.text == "My draft")
        try await eventually { interaction.taskWorkspacePresentation?.inbox.first?.title == "Changed elsewhere" }
        #expect(try await store.read(.task(original.id), in: store.generation) == concurrent)
        #expect(await interaction.commitTaskRename())
        try await eventually { interaction.taskWorkspacePresentation?.inbox.first?.title == "My draft" }
        #expect(interaction.taskWorkspacePresentation?.editing == nil)
        #expect(await interaction.performTaskAction(.rename))
        interaction.editTaskTitle("Discarded")
        interaction.cancelTaskRename()
        #expect(interaction.taskWorkspacePresentation?.editing == nil)
        #expect(try await store.read(.task(original.id), in: store.generation)?.title == "My draft")
        await store.close()
    }

    @Test(arguments: ["return", "focusLoss", "escape"])
    func nativeInlineEditorCommitsOrCancels(command: String) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let original = try await store.perform(.createTask(operation: UUID(), title: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        let window = try #require(interaction.window(for: .main))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.count == 1 }
        interaction.selectTask(original.id)
        #expect(await interaction.performTaskAction(.rename))
        try await eventually { taskEditor(in: window.contentView) != nil }
        let editor = try #require(taskEditor(in: window.contentView))
        #expect(window.makeFirstResponder(editor))
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText("Renamed", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.taskWorkspacePresentation?.editing?.text == "Renamed")
        switch command {
        case "return": editor.keyDown(with: try taskKey(window: window, characters: "\r", code: 36))
        case "escape": editor.keyDown(with: try taskKey(window: window, characters: "\u{1b}", code: 53))
        default: #expect(window.makeFirstResponder(nil))
        }
        try await eventually { interaction.taskWorkspacePresentation?.editing == nil }
        let saved = try await store.read(.task(original.id), in: store.generation)
        #expect(saved?.title == (command == "escape" ? "Original" : "Renamed"))
        await store.close()
    }

    @Test func nativePasteIsRefusedWholeAndBlankReturnKeepsEditor() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let original = try await store.perform(.createTask(operation: UUID(), title: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        let window = try #require(interaction.window(for: .main))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.count == 1 }
        interaction.selectTask(original.id)
        #expect(await interaction.performTaskAction(.rename))
        try await eventually { taskEditor(in: window.contentView) != nil }
        let editor = try #require(taskEditor(in: window.contentView))
        window.makeFirstResponder(editor)
        let pasteboard = NSPasteboard.general
        let contents = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        defer { pasteboard.clearContents(); pasteboard.writeObjects(contents) }
        pasteboard.clearContents()
        pasteboard.setString("first\r\nsecond", forType: .string)
        editor.paste(nil)
        #expect(editor.string == "Original")
        #expect(interaction.taskWorkspacePresentation?.editing?.text == "Original")
        #expect(interaction.taskWorkspacePresentation?.notice != nil)
        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await eventually { interaction.taskWorkspacePresentation?.notice != nil }
        #expect(interaction.taskWorkspacePresentation?.editing?.text == " ")
        #expect(editor.string == " ")
        #expect(try await store.read(.task(original.id), in: store.generation) == original)
        interaction.cancelTaskRename()
        await store.close()
    }

    @Test func taskMenuCommandsHaveKeyEquivalentsAndRouteSelectedTask() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let task = try await store.perform(.createTask(operation: UUID(), title: "Menu task"), in: store.generation)
        let previousMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let interaction = MacInteraction(collection: Task { store })
        interaction.start()
        defer { interaction.stop(); NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindowsMenu }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.count == 1 }
        interaction.selectTask(task.id)
        let menu = try #require(NSApp.mainMenu?.item(withTitle: "Tasks")?.submenu)
        #expect(menu.items.map(\.title) == ["Complete Task", "Move to Today", "Move to Inbox", "Rename Task", "Archive Task", "Move Up", "Move Down"])
        #expect(menu.items.allSatisfy { !$0.keyEquivalent.isEmpty })
        #expect(Set(menu.items.map { $0.keyEquivalent }).count == 7)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Rename Task"))
        try await eventually { interaction.taskWorkspacePresentation?.editing != nil }
        #expect(interaction.canPerformTaskAction(.complete) == false)
        #expect(interaction.canPerformTaskAction(.archive) == false)
        interaction.cancelTaskRename()
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Complete Task"))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.isEmpty == true }
        #expect(try await store.read(.task(task.id), in: store.generation)?.completedAt != nil)
        await store.close()
    }

}


@MainActor
private func taskEditor(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let editor = view as? NSTextView, editor.identifier?.rawValue == "task-title-editor" { return editor }
    for child in view.subviews { if let editor = taskEditor(in: child) { return editor } }
    return nil
}

@MainActor
private func taskKey(window: NSWindow, characters: String, code: UInt16) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                 windowNumber: window.windowNumber, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
}
