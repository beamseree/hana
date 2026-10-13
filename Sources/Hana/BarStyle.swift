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
    static let bezelRadius: CGFloat = 26
    static let cardRadius = bezelRadius - inset
    /// Card padding around the input row and the results, and the gap between them.
    static let cardPadding: CGFloat = 8
    /// Larger than the mode icon so app artwork reads at a glance.
    nonisolated static let resultIconSize: CGFloat = 32
    /// Result icons sit this far inside the row highlight.
    static let resultIconInset: CGFloat = 10
    /// The mode icon and result icons share this center line, in card coordinates.
    static let iconColumnMidX = cardPadding + resultIconInset + resultIconSize / 2
    static let modeIconFrame = NSRect(x: iconColumnMidX - 14, y: 16, width: 28, height: 28)
    /// Where query text and result names begin, in card coordinates.
    static let textInset: CGFloat = 58

    static let font = NSFont.systemFont(ofSize: 26)
    static let textColor = NSColor(srgbRed: 0x17 / 255, green: 0x17 / 255, blue: 0x17 / 255, alpha: 1)
    static let secondaryColor = NSColor(srgbRed: 0x66 / 255, green: 0x66 / 255, blue: 0x66 / 255, alpha: 1)
    static let iconColor = NSColor(srgbRed: 0x77 / 255, green: 0x77 / 255, blue: 0x77 / 255, alpha: 1)
    static let textAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .kern: -0.26]
    static let placeholderAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: secondaryColor, .kern: -0.26]
}

extension NSView {
    static func card(frame: NSRect) -> NSView {
        let card = NSView(frame: frame)
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
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
