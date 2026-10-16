import AppKit
import Observation

enum NoteSaveAction: Equatable { case retry, copyText, discardChanges }

@MainActor
final class NoteWindowController: NSWindowController, NSTextViewDelegate {
    let session: NoteEditingSession
    let preview: NotePreviewSession
    let previewToggle = NSButton(checkboxWithTitle: "Preview", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private let previewSurface: MarkdownPreviewSurface
    private let editorScroll = NSScrollView()
    let editor = NoteEditor(frame: .zero)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Text", target: nil, action: nil)
    var statusText: String { message.stringValue }
    var availableActions: [NoteSaveAction] {
        if closeIsHeld { return [.retry, .copyText, .discardChanges] }
        var actions: [NoteSaveAction] = []
        if !retryButton.isHidden { actions.append(.retry) }
        if !copyButton.isHidden { actions.append(.copyText) }
        return actions
    }
    var onTitleChange: (() -> Void)?
    var onOrganization: (@MainActor (NoteOrganizationAction) async throws -> Void)?
    private var organizationNotice: String?
    var canRestore: Bool { session.committed.archivedAt != nil && session.canOrganize }
    var allowsClose = false
    private var renderedTextRevision: UInt64 = 0
    private var renderedPreviewVisible = false
    private var closeTask: Task<Void, Never>?
    private enum ClosePurpose { case close, quit }
    private var closePurpose: ClosePurpose?
    private var closeAlert: NSAlert?
    private var closePromptID: UUID?
    var closeIsHeld: Bool { closePurpose != nil }

    init(session: NoteEditingSession, previewParser: @escaping MarkdownPreviewParser = MarkdownPreview.parse,
         openPreviewLink: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.session = session
        preview = NotePreviewSession(editing: session, parser: previewParser)
        previewSurface = MarkdownPreviewSurface(openLink: openPreviewLink)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 260)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = HanaColor.Surface.window
        let scroll = editorScroll
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isContinuousSpellCheckingEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.font = HanaFont.Note.body.nsFont
        editor.defaultParagraphStyle = HanaFont.Note.body.wrappedParagraphStyle
        editor.typingAttributes = HanaFont.Note.body.wrappedAttributes(color: HanaColor.Text.primary)
        editor.textColor = HanaColor.Text.primary
        editor.backgroundColor = HanaColor.Surface.window
        editor.textContainerInset = NSSize(width: 20, height: 20)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 660, height: CGFloat.greatestFiniteMagnitude)
        editor.string = session.text
        editor.delegate = self
        editor.onCompositionChange = { [weak self] in self?.changed() }
        editor.setAccessibilityLabel("Note text")
        scroll.documentView = editor
        message.font = HanaFont.detail.nsFont
        message.textColor = HanaColor.Text.secondary
        message.setAccessibilityLabel("Save status")
        retryButton.target = self
        retryButton.action = #selector(retrySave)
        copyButton.target = self
        copyButton.action = #selector(copyText)
        let status = NSStackView(views: [message, retryButton, copyButton])
        status.orientation = .horizontal
        status.alignment = .centerY
        status.spacing = 8
        message.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewToggle.target = self
        previewToggle.action = #selector(togglePreview)
        previewToggle.font = HanaFont.label.nsFont
        previewToggle.setAccessibilityLabel("Show Markdown preview")
        restoreButton.target = self
        restoreButton.action = #selector(restoreArchivedNote)
        restoreButton.keyEquivalent = "r"
        restoreButton.keyEquivalentModifierMask = [.command, .control]
        restoreButton.setAccessibilityLabel("Restore note")
        let toolbar = NSStackView(views: [previewToggle, restoreButton])
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        let stack = NSStackView(views: [toolbar, scroll, previewSurface.scroll, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewSurface.scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor, constant: -20)
        ])
        window.contentView = content
        window.center()
        refresh()
    }

    func perform(_ action: NoteSaveAction) async {
        switch action {
        case .retry:
            commitComposition()
            if closePurpose == .close {
                if let closeTask { await closeTask.value }
                if !allowsClose { await closeSession() }
            } else {
                do {
                    try await session.retry()
                    closePurpose = nil
                    dismissCloseSheet()
                } catch { if closeIsHeld { showCloseChoices() } }
            }
        case .copyText:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.text, forType: .string)
            if closeIsHeld { showCloseChoices() }
        case .discardChanges:
            guard closeIsHeld else { return }
            session.discardChanges()
            allowsClose = true
            closePurpose = nil
            dismissCloseSheet()
            closeTask?.cancel()
            window?.close()
        }
        refresh()
    }

    @objc private func retrySave() { Task { await perform(.retry) } }
    @objc private func copyText() { Task { await perform(.copyText) } }

    func focus(atEnd: Bool = false) {
        guard let window else { return }
        if atEnd { editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)) }
        window.makeFirstResponder(preview.isVisible ? previewSurface.reader : editor)
    }

    @objc private func togglePreview() {
        guard !session.isEditingSuspended else { return }
        preview.setVisible(!preview.isVisible)
    }

    @objc private func restoreArchivedNote() { Task { await performOrganization(.restore) } }

    @discardableResult
    func performOrganization(_ action: NoteOrganizationAction) async -> Bool {
        guard session.canOrganize, let onOrganization else { return false }
        organizationNotice = nil
        do { try await onOrganization(action); refresh(); return true }
        catch {
            organizationNotice = error as? NoteOrganizationError == .compositionActive
                ? "Finish composing text before organizing this note."
                : "The note couldn’t be organized. Your text is still here; try again."
            refresh()
            return false
        }
    }

    func textDidChange(_ notification: Notification) { changed() }
    private func changed() {
        guard session.isEditable else {
            editor.string = session.text
            return
        }
        session.edit(editor.string, isComposing: editor.hasMarkedText())
        renderedTextRevision = session.textRevision
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        session.isEditable
    }

    func suspendEditing(_ suspended: Bool) {
        session.suspendEditing(suspended)
        editor.isEditable = session.isEditable
        previewToggle.isEnabled = !suspended
        restoreButton.isEnabled = canRestore
    }

    func commitComposition() {
        if editor.hasMarkedText() { editor.unmarkText() }
    }

    func shouldClose() -> Bool {
        if allowsClose { return true }
        guard closeTask == nil else { return false }
        commitComposition()
        closePurpose = .close
        if session.canRetry || (session.state == .invalidated && session.hasUnsavedChanges) {
            showCloseChoices()
            return false
        }
        if session.hasUnsavedChanges || session.canRetry || session.state == .saving { showCloseChoices() }
        closeTask = Task { [weak self] in
            guard let self else { return }
            defer { closeTask = nil }
            await closeSession()
        }
        return false
    }

    func holdQuitAfterFailure() {
        closePurpose = .quit
        showCloseChoices()
    }

    func clearQuitHold() {
        closePurpose = nil
        dismissCloseSheet()
    }

    private func closeSession() async {
        do {
            try await session.close()
            guard !allowsClose else { return }
            allowsClose = true
            closePurpose = nil
            dismissCloseSheet()
            window?.close()
        } catch {
            guard !allowsClose else { return }
            refresh()
            showCloseChoices()
        }
    }

    private func showCloseChoices() {
        guard let window, closeAlert == nil, closePurpose != nil else { return }
        let alert = NSAlert()
        alert.messageText = "This note has changes that aren’t saved."
        alert.informativeText = session.status
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Copy Text")
        let discard = alert.addButton(withTitle: "Discard Changes")
        discard.hasDestructiveAction = true
        discard.keyEquivalent = ""
        let identifier = UUID()
        closePromptID = identifier
        closeAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self, closePromptID == identifier else { return }
                closePromptID = nil
                closeAlert = nil
                switch response {
                case .alertFirstButtonReturn: await perform(.retry)
                case .alertSecondButtonReturn: await perform(.copyText)
                case .alertThirdButtonReturn: await perform(.discardChanges)
                default: break
                }
            }
        }
    }

    private func dismissCloseSheet() {
        let sheet = closeAlert?.window
        closeAlert = nil
        closePromptID = nil
        if let sheet { window?.endSheet(sheet, returnCode: .abort) }
    }

    private func refresh() {
        withObservationTracking {
            window?.title = session.committed.title ?? "Untitled"
            previewToggle.state = preview.isVisible ? .on : .off
            editorScroll.isHidden = preview.isVisible
            previewSurface.scroll.isHidden = !preview.isVisible
            if renderedPreviewVisible != preview.isVisible {
                renderedPreviewVisible = preview.isVisible
                window?.makeFirstResponder(preview.isVisible ? previewSurface.reader : editor)
            }
            previewSurface.show(preview.document, isParsing: preview.isParsing)
            editor.isEditable = session.isEditable
            restoreButton.isHidden = session.committed.archivedAt == nil
            restoreButton.isEnabled = canRestore
            if renderedTextRevision != session.textRevision, !editor.hasMarkedText() {
                editor.string = session.text
                renderedTextRevision = session.textRevision
            }
            message.stringValue = organizationNotice ?? session.status
            closeAlert?.informativeText = session.status
            retryButton.isHidden = !session.canRetry
            copyButton.isHidden = !session.canRetry && session.state != .invalidated
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.onTitleChange?()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(session:)") }
}

/// Keeps composition state visible without drawing or asking for TextKit 1.
@MainActor
final class NoteEditor: NSTextView {
    var onCompositionChange: (() -> Void)?
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard isEditable else { return }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?()
    }
    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard isEditable else { return }
        let wasMarked = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        if wasMarked { onCompositionChange?() }
    }
}
