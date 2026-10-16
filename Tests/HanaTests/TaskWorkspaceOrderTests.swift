import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct TaskWorkspaceOrderTests {
    @Test func keyboardOrderingKeepsListsIndependentAndSurvivesReopen() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let inbox = try await taskList(3, in: .inbox, store: store)
        let today = try await taskList(2, in: .today, store: store)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == inbox.map(\.id) }
        interaction.selectTask(inbox[1].id)
        #expect(await interaction.performTaskAction(.moveUp))
        let firstOrder = [inbox[1].id, inbox[0].id, inbox[2].id]
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == firstOrder }
        #expect(!interaction.canPerformTaskAction(.moveUp))
        #expect(await interaction.performTaskAction(.moveDown))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == inbox.map(\.id) }
        interaction.open(.main, section: .today)
        interaction.selectTask(today[0].id)
        #expect(await interaction.performTaskAction(.moveDown))
        let finalToday = [today[1].id, today[0].id]
        try await eventually { interaction.taskWorkspacePresentation?.today.map(\.id) == finalToday }
        #expect(!interaction.canPerformTaskAction(.moveDown))
        #expect(interaction.taskWorkspacePresentation?.inbox.map(\.id) == inbox.map(\.id))
        interaction.window(for: .main)?.close()
        await store.close()
        let reopened = try await CollectionStore.open(fixture.location)
        let restoredInteraction = MacInteraction(collection: Task { reopened })
        defer { restoredInteraction.stop() }
        restoredInteraction.open(.main, section: .today)
        try await eventually { restoredInteraction.taskWorkspacePresentation?.today.map(\.id) == finalToday }
        #expect(restoredInteraction.taskWorkspacePresentation?.inbox.map(\.id) == inbox.map(\.id))
        await reopened.close()
    }
    @Test func dragMovesBeforeTargetOrToEndAndRejectsAnotherList() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let inbox = try await taskList(3, in: .inbox, store: store)
        let today = try await taskList(2, in: .today, store: store)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == inbox.map(\.id) }
        let bottomDrag = try #require(interaction.beginTaskDrag(inbox[2].id))
        #expect(await interaction.dropTask(bottomDrag, before: inbox[0].id))
        let firstOrder = [inbox[2].id, inbox[0].id, inbox[1].id]
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == firstOrder }
        let topDrag = try #require(interaction.beginTaskDrag(inbox[2].id))
        #expect(await interaction.dropTask(topDrag, before: nil))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == inbox.map(\.id) }
        let crossing = try #require(interaction.beginTaskDrag(inbox[0].id))
        interaction.open(.main, section: .today)
        let before = try await store.read(.allRecords, in: store.generation)
        #expect(await interaction.dropTask(crossing, before: today[0].id) == false)
        #expect(try await store.read(.allRecords, in: store.generation) == before)
        await store.close()
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.inbox, in: reopened.generation).map(\.id) == inbox.map(\.id))
        #expect(try await reopened.read(.today, in: reopened.generation) == today)
        await reopened.close()
    }

    enum Interleaved: CaseIterable { case createAtTop, moveIn, moveOut, complete }

    @Test(arguments: Interleaved.allCases, [false, true])
    func staleReorderRefreshesWithoutRetryOrLostTasks(change: Interleaved, isDrag: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let inbox = try await taskList(3, in: .inbox, store: store)
        let today = try await taskList(1, in: .today, store: store)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == inbox.map(\.id) }
        interaction.selectTask(inbox[0].id)
        let request = try #require(interaction.requestTaskReorder(.moveDown))
        let drag = try #require(interaction.beginTaskDrag(inbox[0].id))
        let expectedInbox: [UUID]
        switch change {
        case .createAtTop:
            let new = try await store.perform(.createTask(operation: UUID(), title: "Captured meanwhile"), in: store.generation)
            expectedInbox = [new.id] + inbox.map(\.id)
        case .moveIn:
            _ = try await store.perform(.moveTask(today[0].id, to: .inbox, expectedRevision: 1), in: store.generation)
            expectedInbox = [today[0].id] + inbox.map(\.id)
        case .moveOut:
            _ = try await store.perform(.moveTask(inbox[2].id, to: .today, expectedRevision: 1), in: store.generation)
            expectedInbox = [inbox[0].id, inbox[1].id]
        case .complete:
            _ = try await store.perform(.completeTask(inbox[2].id, expectedRevision: 1), in: store.generation)
            expectedInbox = [inbox[0].id, inbox[1].id]
        }
        let before = try await store.read(.allRecords, in: store.generation)
        // Even if the observer already delivered a new value, the in-flight
        // drag/keyboard request must keep the order it began with.
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == expectedInbox }
        let accepted = isDrag
            ? await interaction.dropTask(drag, before: inbox[2].id)
            : await interaction.performTaskReorder(request)
        #expect(!accepted)
        #expect(interaction.taskWorkspacePresentation?.notice?.contains("nothing was moved") == true)
        #expect(interaction.taskWorkspacePresentation?.inbox.map(\.id) == expectedInbox)
        let after = try await store.read(.allRecords, in: store.generation)
        #expect(after == before)
        let activeIDs = (interaction.taskWorkspacePresentation?.inbox ?? []) + (interaction.taskWorkspacePresentation?.today ?? [])
        #expect(Set(activeIDs.map(\.id)).count == activeIDs.count)
        #expect(Set(after.tasks.map(\.id)).count == after.tasks.count)
        await store.close()
    }

    @Test func moveUpDownMenusRouteOrderingAndYieldToInlineEditing() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let inbox = try await taskList(3, in: .inbox, store: store)
        let interaction = MacInteraction(collection: Task { store })
        let previousMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        interaction.start()
        defer { interaction.stop(); NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindowsMenu }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == inbox.map(\.id) }
        interaction.selectTask(inbox[1].id)
        let menu = try #require(NSApp.mainMenu?.item(withTitle: "Tasks")?.submenu)
        let up = try #require(menu.item(withTitle: "Move Up"))
        let down = try #require(menu.item(withTitle: "Move Down"))
        #expect(up.keyEquivalent == "\u{F700}" && down.keyEquivalent == "\u{F701}")
        #expect(up.keyEquivalentModifierMask == [.command, .option])
        #expect(down.keyEquivalentModifierMask == [.command, .option])
        menu.performActionForItem(at: menu.index(of: up))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == [inbox[1].id, inbox[0].id, inbox[2].id] }
        menu.performActionForItem(at: menu.index(of: down))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.map(\.id) == inbox.map(\.id) }
        #expect(await interaction.performTaskAction(.rename))
        #expect(!interaction.canPerformTaskAction(.moveUp))
        #expect(!interaction.canPerformTaskAction(.moveDown))
        #expect(interaction.beginTaskDrag(inbox[1].id) == nil)
        interaction.cancelTaskRename()
        await store.close()
    }

}

@MainActor
private func taskList(_ count: Int, in placement: TaskPlacement, store: CollectionStore) async throws -> [TaskItem] {
    for index in 0..<count {
        _ = try await store.perform(.createTask(operation: UUID(), title: "\(placement) \(index)", placement: placement), in: store.generation)
    }
    return try await store.read(.tasks(in: placement), in: store.generation)
}
