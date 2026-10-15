import AppKit
import Observation
import SwiftUI

enum TaskWorkspaceAction: Int, CaseIterable {
    case complete, moveToToday, moveToInbox, rename, archive

    var title: String {
        switch self {
        case .complete: "Complete Task"
        case .moveToToday: "Move to Today"
        case .moveToInbox: "Move to Inbox"
        case .rename: "Rename Task"
        case .archive: "Archive Task"
        }
    }
}

/// Organizer values and intents shared by Mac Interaction and the native task list.
@MainActor @Observable
final class TaskWorkspacePresentation {
    enum Availability: Equatable { case loading, available, unavailable }
    private(set) var inbox: [TaskItem] = []
    private(set) var today: [TaskItem] = []
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
    private let collection: Task<CollectionStore, any Error>?
    private var observations: [Task<Void, Never>] = []

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
    }

    func select(_ id: UUID?) { selectedID = id }

    func rows(in section: MainSection) -> [TaskItem] {
        switch section { case .inbox: inbox; case .today: today; default: [] }
    }

    func canPerform(_ action: TaskWorkspaceAction, in section: MainSection) -> Bool {
        guard availability == .available, !isPerforming, editing == nil,
              let row = rows(in: section).first(where: { $0.id == selectedID }) else { return false }
        switch action {
        case .moveToToday: return row.placement == .inbox
        case .moveToInbox: return row.placement == .today
        default: return true
        }
    }

    @discardableResult
    func perform(_ action: TaskWorkspaceAction, in section: MainSection) async -> Bool {
        guard canPerform(action, in: section),
              let row = rows(in: section).first(where: { $0.id == selectedID }),
              let collection else { return false }
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
            case .moveToToday: .moveTask(row.id, to: .today, expectedRevision: row.revision)
            case .moveToInbox: .moveTask(row.id, to: .inbox, expectedRevision: row.revision)
            case .archive: .archiveTask(row.id, expectedRevision: row.revision)
            case .rename: preconditionFailure("Rename starts an editor")
            }
            _ = try await store.perform(command, in: store.generation)
            notice = nil
            return true
        } catch {
            notice = "The task change couldn’t be confirmed. Check the current list before trying again."
            return false
        }
    }

    func editTitle(_ text: String) {
        guard !isPerforming else { return }
        editing?.text = text
        notice = nil
    }

    func refuseMultilineInsertion() {
        notice = "Task titles must stay on one line. The pasted text wasn’t inserted."
    }

    func cancelRename() {
        guard !isPerforming else { return }
        editing = nil
        notice = nil
    }

    @discardableResult
    func commitRename() async -> Bool {
        guard let draft = editing, !isPerforming, let collection else { return false }
        do { try TaskItem.validate(title: draft.text) }
        catch {
            notice = error as? CollectionStoreError == .blankTaskTitle
                ? "Give the task a title before saving."
                : "Task titles must stay on one line. Your text is still here."
            return false
        }
        isPerforming = true
        defer { isPerforming = false }
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
                    Text(section == .today ? "No tasks in Today. Move a task here or capture one from the search bar." : "No tasks in Inbox. Capture a task from the search bar to see it here.")
                        .foregroundStyle(Color(nsColor: HanaColor.Text.secondary))
                } else {
                    List(selection: Binding(get: { tasks.selectedID }, set: { tasks.select($0) })) {
                        ForEach(tasks.rows(in: section)) { row in
                            HStack(spacing: 10) {
                                Button {
                                    tasks.select(row.id)
                                    Task { await tasks.perform(.complete, in: section) }
                                } label: {
                                    Image(systemName: "circle")
                                        .foregroundStyle(Color(nsColor: HanaColor.Text.faint))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Complete \(row.title)")
                                .disabled(tasks.editing != nil || tasks.isPerforming)
                                if tasks.editing?.id == row.id {
                                    TaskTitleEditor(tasks: tasks, taskID: row.id).frame(height: 26)
                                } else {
                                    Text(row.title).lineLimit(1).help(row.title)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .onTapGesture(count: 2) {
                                            tasks.select(row.id)
                                            Task { await tasks.perform(.rename, in: section) }
                                        }
                                }
                            }
                            .padding(.vertical, 3)
                            .tag(row.id)
                            .listRowBackground(Color(nsColor: HanaColor.Surface.group))
                            .contextMenu {
                                ForEach(TaskWorkspaceAction.allCases, id: \.rawValue) { action in
                                    Button(action.title) {
                                        tasks.select(row.id)
                                        Task { await tasks.perform(action, in: section) }
                                    }
                                    .disabled(tasks.editing != nil || tasks.isPerforming ||
                                              (action == .moveToInbox && row.placement == .inbox) ||
                                              (action == .moveToToday && row.placement == .today))
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(section.rawValue)
                    .onKeyPress(.return) {
                        guard tasks.canPerform(.rename, in: section) else { return .ignored }
                        Task { await tasks.perform(.rename, in: section) }
                        return .handled
                    }
                }
            }
        }
        .onChange(of: section) { _, _ in Task { await tasks.commitRename() } }
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
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? NSTextView else { return }
        editor.isEditable = !tasks.isPerforming
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
            case .moveToToday: "t"
            case .moveToInbox: "i"
            case .rename: "r"
            case .archive: "a"
            }
            let item = NSMenuItem(title: action.title, action: #selector(run(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = action == .rename ? [.command] : [.command, .shift]
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
        Task { await interaction.performTaskAction(action) }
    }
}
