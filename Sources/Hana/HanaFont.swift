import AppKit
import SwiftUI

/// One type role: the system font at a size, weight and tracking.
/// See docs/design-system.md.
struct FontRole: Sendable {
    enum Weight: Sendable { case regular, medium }

    let size: CGFloat
    /// For wrapped text; single-line text sits in fixed geometry.
    let lineHeight: CGFloat
    let weight: Weight
    /// A fraction of the size: −1% from 16 points up.
    var tracking: CGFloat = 0
    /// Tabular digits, so changing numbers keep their width.
    var tabularDigits = false

    /// Tracking in points, for AppKit's `.kern` and SwiftUI's `tracking`.
    var kern: CGFloat { size * tracking }

    var nsFont: NSFont {
        let weight: NSFont.Weight = weight == .medium ? .medium : .regular
        return tabularDigits
            ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
    }

    var font: Font {
        let font = Font.system(size: size, weight: weight == .medium ? .medium : .regular)
        return tabularDigits ? font.monospacedDigit() : font
    }

    func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: nsFont, .foregroundColor: color, .kern: kern]
    }
}

/// Named type roles. The role `bar.input` in docs/design-system.md is
/// `HanaFont.Bar.input`; `body` is `HanaFont.body`.
enum HanaFont {
    enum Bar {
        /// Search query, Note and Task text, and the placeholder.
        static let input = FontRole(size: 26, lineHeight: 40, weight: .regular, tracking: -0.01)
    }

    enum Heading {
        /// Main window list titles.
        static let window = FontRole(size: 20, lineHeight: 26, weight: .medium, tracking: -0.01)
        /// Group labels in working windows.
        static let section = FontRole(size: 12, lineHeight: 16, weight: .medium)
    }

    enum Row {
        /// Search bar result names.
        static let title = FontRole(size: 16, lineHeight: 20, weight: .regular, tracking: -0.01)
    }

    enum Note {
        /// Writing in a Note window.
        static let body = FontRole(size: 15, lineHeight: 22, weight: .regular)
    }

    /// List rows, task titles, controls and fields.
    static let body = FontRole(size: 13, lineHeight: 18, weight: .regular)
    /// Mode label, notices, buttons and the task destination selector.
    static let label = FontRole(size: 13, lineHeight: 16, weight: .medium)
    /// Paths, type labels and the results status line.
    static let detail = FontRole(size: 12, lineHeight: 16, weight: .regular)
    /// Counts, dates, key hints and shortcuts.
    static let caption = FontRole(size: 11, lineHeight: 14, weight: .regular, tabularDigits: true)
}

extension View {
    func font(_ role: FontRole) -> some View {
        font(role.font).tracking(role.kern)
    }
}
