import AppKit
import Observation

@MainActor
final class NoteWindowController: NSWindowController, NSTextViewDelegate {
    let session: NoteEditingSession
    let editor = NoteEditor(frame: .zero)
    private let message = NSTextField(wrappingLabelWithString: "")
    var onTitleChange: (() -> Void)?
    var allowsClose = false
    private var renderedTextRevision: UInt64 = 0
    private var closeTask: Task<Void, Never>?

    init(session: NoteEditingSession) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 260)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = HanaColor.Surface.window
        let scroll = NSScrollView()
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
        let stack = NSStackView(views: [scroll, message])
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
            message.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor, constant: -20)
        ])
        window.contentView = content
        window.center()
        refresh()
    }

    func focus(atEnd: Bool = false) {
        guard let window else { return }
        if atEnd { editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)) }
        window.makeFirstResponder(editor)
    }

    func textDidChange(_ notification: Notification) { changed() }
    private func changed() {
        session.edit(editor.string, isComposing: editor.hasMarkedText())
        renderedTextRevision = session.textRevision
    }

    func shouldClose() -> Bool {
        if allowsClose { return true }
        guard closeTask == nil else { return false }
        // End the input method transaction before flushing committed text.
        if editor.hasMarkedText() { editor.unmarkText() }
        closeTask = Task { [weak self] in
            guard let self else { return }
            defer { closeTask = nil }
            do {
                try await session.close()
                allowsClose = true
                window?.close()
            } catch { refresh() }
        }
        return false
    }

    private func refresh() {
        withObservationTracking {
            window?.title = session.committed.title ?? "Untitled"
            editor.isEditable = session.isEditable
            if renderedTextRevision != session.textRevision, !editor.hasMarkedText() {
                editor.string = session.text
                renderedTextRevision = session.textRevision
            }
            message.stringValue = session.explanation ?? (session.state == .saving ? "Saving…" : "")
            message.isHidden = message.stringValue.isEmpty
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
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?()
    }
    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasMarked = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        if wasMarked { onCompositionChange?() }
    }
}
