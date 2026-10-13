import AppKit

/// Stable validation destinations; these are not saved collection note IDs.
enum WorkingWindow: Int, CaseIterable {
    case main = 1, mockNoteA, mockNoteB

    var title: String {
        switch self {
        case .main: "Main"
        case .mockNoteA: "Mock Note A"
        case .mockNoteB: "Mock Note B"
        }
    }
}

@MainActor
final class WorkingWindowController: NSWindowController {
    let focusProbe = NSTextField(string: "")

    init(destination: WorkingWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 260),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "Hana — \(destination.title) — validation only"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 250)
        window.center()
        window.setFrameOrigin(NSPoint(x: window.frame.minX + CGFloat(destination.rawValue - 1) * 40,
                                      y: window.frame.minY - CGFloat(destination.rawValue - 1) * 35))

        let title = NSTextField(labelWithString: "\(destination.title) · Validation only")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let disclaimer = NSTextField(wrappingLabelWithString:
            "Mock content. Nothing is saved. No note editing or organizer.")
        let probeLabel = NSTextField(wrappingLabelWithString:
            "Keyboard focus probe — temporary text, discarded on close. This is not a note editor.")
        focusProbe.placeholderString = "Type here to check destination focus"
        focusProbe.setAccessibilityLabel("\(destination.title) keyboard focus probe")
        let shortcuts = NSTextField(labelWithString: "Window menu: ⌘1 Main · ⌘2 Mock Note A · ⌘3 Mock Note B")
        shortcuts.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [title, disclaimer, probeLabel, focusProbe, shortcuts])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            focusProbe.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.initialFirstResponder = focusProbe
    }

    required init?(coder: NSCoder) { fatalError("Use init(destination:)") }
}
