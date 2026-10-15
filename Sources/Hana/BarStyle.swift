import AppKit

/// Search bar appearance from the Figma "hana" page (Port 2025, node 470:2289;
/// expanded state "Expanded — Redesigned #2", 470:2532): a translucent bezel around
/// one opaque white card, always light.
@MainActor
enum BarStyle {
    static let width: CGFloat = 660
    static let inset: CGFloat = 4
    static let inputHeight: CGFloat = 60
    static let collapsedHeight = inputHeight + 2 * inset
    static let bezelRadius = HanaRadius.bar
    static let cardRadius = HanaRadius.nested(in: bezelRadius, inset: inset)
    /// Card padding around the input row and the results, and the gap between them.
    static let cardPadding: CGFloat = 8
    /// The selected result's highlight, concentric with the card.
    static let rowRadius = HanaRadius.nested(in: cardRadius, inset: cardPadding)
    /// Card height changes. Short because Search is invoked many times a day.
    static let resizeDuration: TimeInterval = 0.15
    /// Strong ease-out, cubic-bezier(0.23, 1, 0.32, 1).
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    /// Larger than the mode icon so app artwork reads at a glance.
    nonisolated static let resultIconSize: CGFloat = 32
    /// Result icons sit this far inside the row highlight.
    static let resultIconInset: CGFloat = 10
    /// The mode icon and result icons share this center line, in card coordinates.
    static let iconColumnMidX = cardPadding + resultIconInset + resultIconSize / 2
    static let modeIconFrame = NSRect(x: iconColumnMidX - 14, y: 16, width: 28, height: 28)
    /// Where query text and result names begin, in card coordinates.
    static let textInset: CGFloat = 58
    /// The editor's single-line height, and its inset below the card's top.
    static let editorHeight: CGFloat = 40
    static let editorTopInset: CGFloat = 10
    /// Note's writing surface grows to this text height, then scrolls.
    static let noteMaxTextHeight: CGFloat = 240
    /// A capture's one-line explanation below the writing surface.
    static let noticeHeight: CGFloat = 24

    /// Colors and type are `HanaColor` and `HanaFont` roles; see docs/design-system.md.
    static let textAttributes = HanaFont.Bar.input.attributes(color: HanaColor.Text.primary)
    static let placeholderAttributes = HanaFont.Bar.input.attributes(color: HanaColor.Text.placeholder)
}

extension NSView {
    static func card(frame: NSRect) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = HanaColor.Surface.card.cgColor
        card.layer?.cornerRadius = BarStyle.cardRadius
        card.layer?.masksToBounds = true
        return card
    }
}

extension NSImage {
    /// Bundled by scripts/build; absent when running unbundled through SwiftPM.
    static let hanaLogo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "HanaLogo", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        // A template so mode icons share one tint.
        image.isTemplate = true
        return image
    }()

    /// A menu-bar-sized copy, so resizing it leaves the bar's mode icon alone.
    static let hanaStatusLogo: NSImage? = {
        guard let image = hanaLogo?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()

    /// A resizable rounded-rectangle mask, so the material and the window shadow follow the bezel's corners.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
