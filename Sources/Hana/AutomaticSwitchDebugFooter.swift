import AppKit

/// A fixed-height, passive footer shared by Search, Note and Task. Long
/// diagnostics remain available in accessibility text and the tooltip.
@MainActor
final class AutomaticSwitchDebugFooter: NSView {
    static let height: CGFloat = 46
    private let summary = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let divider = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width]
        isHidden = true
        divider.boxType = .separator
        addSubview(divider)
        for label in [summary, detail] {
            label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            label.textColor = HanaColor.Text.secondary
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let leading = BarStyle.textInset
        let width = max(0, bounds.width - leading - BarStyle.cardPadding - BarStyle.resultIconInset)
        summary.frame = NSRect(x: leading, y: 25, width: width, height: 14)
        detail.frame = NSRect(x: leading, y: 9, width: width, height: 14)
        divider.frame = NSRect(x: BarStyle.cardPadding + BarStyle.resultIconInset, y: Self.height - 1,
            width: bounds.width - 2 * (BarStyle.cardPadding + BarStyle.resultIconInset), height: 1)
    }

    func show(summary: String, detail: String) {
        self.summary.stringValue = summary
        self.detail.stringValue = detail
        self.summary.setAccessibilityLabel(summary)
        self.detail.setAccessibilityLabel(detail)
        toolTip = summary + "\n" + detail + "\n\nRequest numbers count classification attempts. Sent counts Jev HTTP starts in this bar session. Live includes HTTP work from earlier sessions."
    }

    var text: String { summary.stringValue + "\n" + detail.stringValue }
}
