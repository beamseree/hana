import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum TaskWorkspaceAction: Int, CaseIterable, Sendable {
    case complete, reopen, moveToToday, moveToInbox, rename, archive, moveUp, moveDown

    var title: String {
        switch self {
        case .complete: "Complete Task"
        case .reopen: "Reopen Task"
        case .moveToToday: "Move to Today"
        case .moveToInbox: "Move to Inbox"
        case .rename: "Rename Task"
        case .archive: "Archive Task"
        case .moveUp: "Move Up"
        case .moveDown: "Move Down"
        }
    }
}

struct TaskActionRequest: Sendable {
    let action: TaskWorkspaceAction
    let id: UUID
    let expectedRevision: Int64
    let section: MainSection
}

/// A user intent carries the order the user saw, rather than recomputing a
/// position after an asynchronous Store opening or a concurrent capture.
struct TaskReorderRequest: Sendable {
    let id: UUID
    let placement: TaskPlacement
    let predecessor: UUID?
    let expectedOrder: [UUID]
}

/// The drag freezes the visible order; only IDs and placement cross the native
/// drag pasteboard. An Inbox payload cannot be used as a Today move command.
struct TaskOrderDrag: Codable, Sendable, Transferable {
    let id: UUID
    let placement: String
    let expectedOrder: [UUID]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .hanaTaskOrder)
    }
}

private extension UTType {
    static let hanaTaskOrder = UTType(exportedAs: "com.beamseree.hana.task-order", conformingTo: .data)
}

/// Organizer values and intents shared by Mac Interaction and the native task list.
@MainActor @Observable
final class TaskWorkspacePresentation {
    enum Availability: Equatable { case loading, available, unavailable }
    private(set) var inbox: [TaskItem] = []
    private(set) var today: [TaskItem] = []
    private(set) var completed: [TaskItem] = []
    private(set) var availability: Availability = .loading
    struct Editing: Equatable {
        let id: UUID
        var expectedRevision: Int64
        var text: String
    }
    private(set) var editing: Editing?
    private(set) var selectedID: UUID?
    private(set) var notice: String?
    private(set) var isPerforming = false
    private(set) var isEditingSuspended = false
    fileprivate weak var titleEditor: NSTextView?
    var isTitleEditable: Bool { !isPerforming && !isEditingSuspended }

    func suspendEditing(_ suspended: Bool) {
        if suspended, let editor = titleEditor, editor.hasMarkedText() { editor.unmarkText(); editTitle(editor.string) }
        isEditingSuspended = suspended
        titleEditor?.isEditable = isTitleEditable
    }

    func focusRename() {
        if let editor = titleEditor, editing != nil { editor.window?.makeFirstResponder(editor) }
    }
    private let collection: Task<CollectionStore, any Error>?
    private var observations: [Task<Void, Never>] = []
    private var renameSave: Task<Bool, Never>?

    init(collection: Task<CollectionStore, any Error>?) {
        self.collection = collection
        guard let collection else { availability = .unavailable; return }
        for placement in TaskPlacement.allCases {
            observations.append(Task { [weak self] in
                do {
                    let store = try await collection.value
                    for try await rows in store.observe(.tasks(in: placement), in: store.generation) {
                        guard !Task.isCancelled else { return }
                        if placement == .inbox { self?.inbox = rows } else { self?.today = rows }
                        self?.availability = .available
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.inbox = []
                    self?.today = []
                    self?.availability = .unavailable
                }
            })
        }
        observations.append(Task { [weak self] in
            do {
                let store = try await collection.value
                for try await rows in store.observe(.completedTasks, in: store.generation) {
                    guard !Task.isCancelled else { return }
                    self?.completed = rows
                    self?.availability = .available
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.completed = []
                self?.availability = .unavailable
            }
        })
    }

    func select(_ id: UUID?) { selectedID = id }

    func rows(in section: MainSection) -> [TaskItem] {
        switch section { case .inbox: inbox; case .today: today; case .completed: completed; default: [] }
    }

    func canPerform(_ action: TaskWorkspaceAction, in section: MainSection, taskID: UUID? = nil) -> Bool {
        guard availability == .available, !isEditingSuspended, !isPerforming, editing == nil,
              let row = rows(in: section).first(where: { $0.id == (taskID ?? selectedID) }) else { return false }
        switch action {
        case .complete: return section != .completed
        case .reopen: return section == .completed
        case .moveToToday: return section == .inbox
        case .moveToInbox: return section == .today
        case .moveUp: return section.taskPlacement != nil && rows(in: section).first?.id != row.id
        case .moveDown: return section.taskPlacement != nil && rows(in: section).last?.id != row.id
        default: return true
        }
    }

    func requestAction(_ action: TaskWorkspaceAction, in section: MainSection, task: TaskItem? = nil) -> TaskActionRequest? {
        guard action != .moveUp, action != .moveDown,
              canPerform(action, in: section, taskID: task?.id),
              let row = task ?? rows(in: section).first(where: { $0.id == selectedID }) else { return nil }
        return TaskActionRequest(action: action, id: row.id, expectedRevision: row.revision, section: section)
    }

    @discardableResult
    func perform(_ action: TaskWorkspaceAction, in section: MainSection) async -> Bool {
        if action == .moveUp || action == .moveDown {
            guard let request = requestReorder(action, in: section) else { return false }
            return await reorder(request)
        }
        guard let request = requestAction(action, in: section) else { return false }
        return await perform(request)
    }

    @discardableResult
    func perform(_ request: TaskActionRequest) async -> Bool {
        let action = request.action
        guard canPerform(action, in: request.section, taskID: request.id), let collection else { return false }
        guard let row = rows(in: request.section).first(where: { $0.id == request.id }), row.revision == request.expectedRevision else {
            notice = "This task changed. Review its latest version before trying again."
            return false
        }
        if action == .rename {
            editing = Editing(id: row.id, expectedRevision: row.revision, text: row.title)
            notice = nil
            return true
        }
        isPerforming = true
        defer { isPerforming = false }
        do {
            let store = try await collection.value
            let command: CollectionCommand<TaskItem> = switch action {
            case .complete: .completeTask(row.id, expectedRevision: row.revision)
            case .reopen: .reopenTask(row.id, expectedRevision: row.revision)
            case .moveToToday: .moveTask(row.id, to: .today, expectedRevision: row.revision)
            case .moveToInbox: .moveTask(row.id, to: .inbox, expectedRevision: row.revision)
            case .archive: .archiveTask(row.id, expectedRevision: row.revision)
            case .rename, .moveUp, .moveDown: preconditionFailure("Handled before status commands")
            }
            _ = try await store.perform(command, in: store.generation)
            notice = nil
            return true
        } catch {
            notice = "The task change couldn’t be confirmed. Check the current list before trying again."
            return false
        }
    }

    func requestReorder(_ action: TaskWorkspaceAction, in section: MainSection) -> TaskReorderRequest? {
        guard (action == .moveUp || action == .moveDown), canPerform(action, in: section),
              let id = selectedID, let placement = section.taskPlacement else { return nil }
        let order = rows(in: section).map(\.id)
        guard let index = order.firstIndex(of: id) else { return nil }
        let predecessor = action == .moveUp ? (index > 1 ? order[index - 2] : nil) : order[index + 1]
        return TaskReorderRequest(id: id, placement: placement, predecessor: predecessor, expectedOrder: order)
    }

    @discardableResult
    func reorder(_ request: TaskReorderRequest) async -> Bool {
        guard availability == .available, !isEditingSuspended, editing == nil, !isPerforming, let collection else { return false }
        isPerforming = true
        defer { isPerforming = false }
        do {
            let store = try await collection.value
            _ = try await store.perform(.reorderTask(request.id, in: request.placement, after: request.predecessor,
                                                    expectedOrder: request.expectedOrder), in: store.generation)
            notice = nil
            return true
        } catch {
            if error as? CollectionStoreError == .staleList,
               let store = try? await collection.value,
               let current = try? await store.read(.tasks(in: request.placement), in: store.generation) {
                if request.placement == .inbox { inbox = current } else { today = current }
                notice = "The task order changed. The list is refreshed; nothing was moved. Review it before trying again."
            } else {
                notice = "The task order couldn’t be confirmed. Check the current list before trying again."
            }
            return false
        }
    }

    func beginDrag(_ id: UUID, in section: MainSection) -> TaskOrderDrag? {
        guard availability == .available, !isEditingSuspended, !isPerforming, editing == nil,
              let placement = section.taskPlacement,
              rows(in: section).contains(where: { $0.id == id }) else { return nil }
        return TaskOrderDrag(id: id, placement: placement.rawValue, expectedOrder: rows(in: section).map(\.id))
    }

    func requestDrop(_ drag: TaskOrderDrag, before target: UUID?, in section: MainSection) -> TaskReorderRequest? {
        guard let placement = section.taskPlacement, placement.rawValue == drag.placement,
              let sourceIndex = drag.expectedOrder.firstIndex(of: drag.id) else { return nil }
        let remaining = drag.expectedOrder.filter { $0 != drag.id }
        let predecessor: UUID?
        if target == drag.id {
            predecessor = sourceIndex > 0 ? drag.expectedOrder[sourceIndex - 1] : nil
        } else if let target {
            guard let targetIndex = remaining.firstIndex(of: target) else { return nil }
            predecessor = targetIndex > 0 ? remaining[targetIndex - 1] : nil
        } else {
            predecessor = remaining.last
        }
        return TaskReorderRequest(id: drag.id, placement: placement, predecessor: predecessor, expectedOrder: drag.expectedOrder)
    }

    @discardableResult
    func drop(_ drag: TaskOrderDrag, before target: UUID?, in section: MainSection) async -> Bool {
        guard let request = requestDrop(drag, before: target, in: section) else { return false }
        return await reorder(request)
    }

    func editTitle(_ text: String) {
        guard isTitleEditable else { return }
        editing?.text = text
        notice = nil
    }

    func refuseMultilineInsertion() {
        notice = "Task titles must stay on one line. The pasted text wasn’t inserted."
    }

    func cancelRename() {
        guard isTitleEditable else { return }
        editing = nil
        notice = nil
    }

    @discardableResult
    func commitRename() async -> Bool {
        if let renameSave { return await renameSave.value }
        guard let draft = editing, !isPerforming, let collection else { return false }
        do { try TaskItem.validate(title: draft.text) }
        catch {
            notice = error as? CollectionStoreError == .blankTaskTitle
                ? "Give the task a title before saving."
                : "Task titles must stay on one line. Your text is still here."
            return false
        }
        isPerforming = true
        let saving = Task { @MainActor in
            defer { self.isPerforming = false; self.renameSave = nil }
            return await self.saveRename(draft, in: collection)
        }
        renameSave = saving
        return await saving.value
    }

    private func saveRename(_ draft: Editing, in collection: Task<CollectionStore, any Error>) async -> Bool {
        do {
            let store = try await collection.value
            _ = try await store.perform(.editTaskTitle(draft.id, expectedRevision: draft.expectedRevision, title: draft.text), in: store.generation)
            editing = nil
            notice = nil
            return true
        } catch {
            if error as? CollectionStoreError == .staleRevision,
               let store = try? await collection.value,
               let committed = try? await store.read(.task(draft.id), in: store.generation) {
                // Reload the committed row, but keep the draft until the user
                // explicitly retries or cancels. Never overwrite automatically.
                if let index = inbox.firstIndex(where: { $0.id == committed.id }) { inbox[index] = committed }
                if let index = today.firstIndex(where: { $0.id == committed.id }) { today[index] = committed }
                if let index = completed.firstIndex(where: { $0.id == committed.id }) { completed[index] = committed }
                editing?.expectedRevision = committed.revision
                notice = "This task changed elsewhere. The saved title is \(committed.title). Your draft is kept; Return retries, Escape cancels."
            } else {
                notice = "The title save couldn’t be confirmed. Your text is still here; try again."
            }
            return false
        }
    }

    func stopObserving() {
        observations.forEach { $0.cancel() }
        observations = []
    }

    isolated deinit { observations.forEach { $0.cancel() } }
}

struct TaskWorkspaceView: View {
    let tasks: TaskWorkspacePresentation
    let section: MainSection

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = tasks.notice {
                Text(notice).font(HanaFont.detail.font)
                    .foregroundStyle(Color(nsColor: HanaColor.Status.error))
                    .accessibilityLabel("Task action: \(notice)")
            }
            switch tasks.availability {
            case .loading: ProgressView("Opening tasks…")
            case .unavailable:
                Text("Tasks are unavailable. Close and reopen Hana to try again.")
                    .foregroundStyle(Color(nsColor: HanaColor.Text.secondary))
            case .available:
                if tasks.rows(in: section).isEmpty {
                    Text(section == .completed ? "No completed tasks yet." : section == .today ? "No tasks in Today. Move a task here or capture one from the search bar." : "No tasks in Inbox. Capture a task from the search bar to see it here.")
                        .foregroundStyle(Color(nsColor: HanaColor.Text.secondary))
                } else {
                    List(selection: Binding(get: { tasks.selectedID }, set: { tasks.select($0) })) {
                        ForEach(tasks.rows(in: section)) { row in
                            HStack(spacing: 10) {
                                Button {
                                    tasks.select(row.id)
                                    if let request = tasks.requestAction(section == .completed ? .reopen : .complete, in: section, task: row) {
                                        Task { await tasks.perform(request) }
                                    }
                                } label: {
                                    Image(systemName: section == .completed ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(Color(nsColor: HanaColor.Text.faint))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(section == .completed ? "Reopen" : "Complete") \(row.title)")
                                .disabled(tasks.editing != nil || tasks.isPerforming)
                                if tasks.editing?.id == row.id {
                                    TaskTitleEditor(tasks: tasks, taskID: row.id).frame(height: 26)
                                } else {
                                    Text(row.title).lineLimit(1).help(row.title)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .onTapGesture(count: 2) {
                                            tasks.select(row.id)
                                            if let request = tasks.requestAction(.rename, in: section, task: row) {
                                                Task { await tasks.perform(request) }
                                            }
                                        }
                                }
                            }
                            .padding(.vertical, 3)
                            .modifier(TaskOrderDragModifier(drag: tasks.beginDrag(row.id, in: section)))
                            .modifier(TaskOrderDropModifier(tasks: tasks, section: section, before: row.id))
                            .tag(row.id)
                            .listRowBackground(Color(nsColor: HanaColor.Surface.group))
                            .contextMenu {
                                ForEach(section == .completed ? [.reopen, .rename, .archive] : TaskWorkspaceAction.allCases.filter { $0 != .reopen }, id: \.rawValue) { action in
                                    Button(action.title) {
                                        tasks.select(row.id)
                                        if let request = tasks.requestReorder(action, in: section) {
                                            Task { await tasks.reorder(request) }
                                        } else {
                                            if let request = tasks.requestAction(action, in: section, task: row) {
                                                Task { await tasks.perform(request) }
                                            }
                                        }
                                    }
                                    .disabled(!tasks.canPerform(action, in: section, taskID: row.id))
                                }
                            }
                        }
                        if section.taskPlacement != nil {
                            Color.clear.frame(height: 12)
                                .contentShape(Rectangle())
                                .modifier(TaskOrderDropModifier(tasks: tasks, section: section, before: nil))
                                .accessibilityLabel("Move task to end")
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(section.rawValue)
                    .onKeyPress(.return) {
                        guard let request = tasks.requestAction(.rename, in: section) else { return .ignored }
                        Task { await tasks.perform(request) }
                        return .handled
                    }
                }
            }
        }
    }
}

/// A real AppKit editor keeps text input, selection, paste and composition in
/// the native responder chain instead of rebuilding a SwiftUI field per edit.
private struct TaskTitleEditor: NSViewRepresentable {
    let tasks: TaskWorkspacePresentation
    let taskID: UUID

    func makeCoordinator() -> Coordinator { Coordinator(tasks: tasks, taskID: taskID) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        let editor = InlineTaskTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 26))
        editor.identifier = NSUserInterfaceItemIdentifier("task-title-editor")
        editor.setAccessibilityLabel("Task title")
        editor.delegate = context.coordinator
        editor.onFocusLoss = { Task { await tasks.commitRename() } }
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.drawsBackground = true
        editor.backgroundColor = HanaColor.Surface.card
        editor.textColor = HanaColor.Text.primary
        editor.insertionPointColor = HanaColor.Text.primary
        editor.font = HanaFont.body.nsFont
        editor.textContainerInset = NSSize(width: 3, height: 4)
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = true
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 26)
        editor.string = tasks.editing?.text ?? ""
        scroll.documentView = editor
        context.coordinator.editor = editor
        tasks.titleEditor = editor
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? NSTextView else { return }
        editor.isEditable = tasks.isTitleEditable
        if let draft = tasks.editing, draft.id == taskID, editor.string != draft.text {
            editor.string = draft.text
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let tasks: TaskWorkspacePresentation
        let taskID: UUID
        weak var editor: NSTextView?
        init(tasks: TaskWorkspacePresentation, taskID: UUID) { self.tasks = tasks; self.taskID = taskID }

        func textDidChange(_ notification: Notification) {
            guard tasks.editing?.id == taskID, let editor else { return }
            tasks.editTitle(editor.string)
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            guard tasks.isTitleEditable else { return false }
            guard let replacementString, TaskItem.isMultiline(replacementString) else { return true }
            tasks.refuseMultilineInsertion()
            return false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                Task { await tasks.commitRename() }
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                tasks.cancelRename()
                return true
            }
            return false
        }
    }
}

@MainActor
private final class InlineTaskTextView: NSTextView {
    var onFocusLoss: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            window.makeFirstResponder(self)
            setSelectedRange(NSRange(location: 0, length: (string as NSString).length))
        }
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusLoss?() }
        return resigned
    }
}

/// One retained native menu target; AppKit disables task shortcuts whenever
/// another window or an inline text editor owns keyboard input.
@MainActor
final class TaskWorkspaceMenuTarget: NSObject, NSMenuItemValidation {
    weak var interaction: MacInteraction?

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Tasks")
        for action in TaskWorkspaceAction.allCases {
            let key = switch action {
            case .complete: "k"
            case .reopen: "o"
            case .moveToToday: "t"
            case .moveToInbox: "i"
            case .rename: "r"
            case .archive: "a"
            case .moveUp: "\u{F700}"
            case .moveDown: "\u{F701}"
            }
            let item = NSMenuItem(title: action.title, action: #selector(run(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = switch action {
            case .rename: [.command]
            case .moveUp, .moveDown: [.command, .option]
            default: [.command, .shift]
            }
            item.tag = action.rawValue
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let interaction, NSApp.keyWindow === interaction.window(for: .main),
              let action = TaskWorkspaceAction(rawValue: menuItem.tag) else { return false }
        return interaction.canPerformTaskAction(action)
    }

    @objc private func run(_ item: NSMenuItem) {
        guard let interaction, let action = TaskWorkspaceAction(rawValue: item.tag),
              interaction.canPerformTaskAction(action) else { return }
        if let request = interaction.requestTaskReorder(action) {
            Task { await interaction.performTaskReorder(request) }
        } else {
            guard let request = interaction.requestTaskAction(action) else { return }
            Task { await interaction.performTaskAction(request) }
        }
    }
}

extension MainSection {
    var taskPlacement: TaskPlacement? {
        switch self { case .inbox: .inbox; case .today: .today; default: nil }
    }
}

private struct TaskOrderDragModifier: ViewModifier {
    let drag: TaskOrderDrag?
    @ViewBuilder func body(content: Content) -> some View {
        if let drag { content.draggable(drag) } else { content }
    }
}

private struct TaskOrderDropModifier: ViewModifier {
    let tasks: TaskWorkspacePresentation
    let section: MainSection
    let before: UUID?
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if isTargeted { Rectangle().fill(Color(nsColor: HanaColor.Focus.ring)).frame(height: 1) }
            }
            .dropDestination(for: TaskOrderDrag.self) { drags, _ in
                guard drags.count == 1, let drag = drags.first,
                      let request = tasks.requestDrop(drag, before: before, in: section) else { return false }
                Task { await tasks.reorder(request) }
                return true
            } isTargeted: { isTargeted = $0 }
    }
}
