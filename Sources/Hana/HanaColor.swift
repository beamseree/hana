import AppKit

/// Vercel Geist's light palette, the only raw colors in Hana. Views use
/// `HanaColor` roles, never these steps. See docs/design-system.md.
enum Geist {
    static let gray100 = gray(0xf2)
    static let gray200 = gray(0xeb)
    static let gray300 = gray(0xe6)
    static let gray400 = gray(0xeb)
    static let gray500 = gray(0xc9)
    static let gray600 = gray(0xa8)
    static let gray700 = gray(0x8f)
    static let gray800 = gray(0x7d)
    static let gray900 = gray(0x4d)
    static let gray1000 = gray(0x17)

    static let grayAlpha100 = black(0.05)
    static let grayAlpha200 = black(0.08)
    static let grayAlpha300 = black(0.10)
    static let grayAlpha400 = black(0.08)
    static let grayAlpha500 = black(0.21)
    static let grayAlpha600 = black(0.34)
    static let grayAlpha700 = black(0.44)
    static let grayAlpha800 = black(0.51)
    static let grayAlpha900 = black(0.70)
    static let grayAlpha1000 = black(0.91)

    static let background100 = gray(0xff)
    static let background200 = gray(0xfa)

    /// Geist specifies its hues in Display P3.
    static let red900 = p3(0xc6, 0x21, 0x28)
    static let amber900 = p3(0x9e, 0x52, 0x00)
    static let green900 = p3(0x39, 0x7c, 0x3b)

    private static func gray(_ value: Int) -> NSColor {
        let component = CGFloat(value) / 255
        return NSColor(srgbRed: component, green: component, blue: component, alpha: 1)
    }

    private static func black(_ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha)
    }

    private static func p3(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
        NSColor(displayP3Red: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
}

/// Named color roles, each one Geist step or a value Geist lacks. The role
/// `text.primary` in docs/design-system.md is `HanaColor.Text.primary`.
enum HanaColor {
    enum Surface {
        /// Main window and Note window backgrounds.
        static let window = Geist.background200
        /// The Search bar's card; the selected segment of a segmented control.
        static let card = Geist.background100
        /// Grouped lists in working windows.
        static let group = Geist.gray100
        static let groupHover = Geist.gray300
    }

    enum Bezel {
        /// Over the behind-window material; lighter than Figma's 72% so the blur shows.
        static let tint = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35)
    }

    enum Control {
        /// Segmented controls, search fields and chips.
        static let fill = Geist.gray200
        static let hover = Geist.gray300
    }

    enum Row {
        static let hover = Geist.grayAlpha100
        static let selected = Geist.grayAlpha200
    }

    enum Fill {
        /// The one primary button in a view.
        static let primary = Geist.gray1000
    }

    enum Scroll {
        static let thumb = Geist.grayAlpha500
    }

    enum Text {
        /// Typed text, names and titles; also the insertion point.
        static let primary = Geist.gray1000
        /// Paths, mode labels, notices and supporting text.
        static let secondary = Geist.gray900
        /// Type labels, counts, dates and section labels.
        static let tertiary = Geist.gray800
        static let placeholder = Geist.gray800
        /// Separators and unchecked task circles.
        static let faint = Geist.gray500
        static let onPrimary = Geist.background100
    }

    enum Icon {
        /// Mode icons and active icons.
        static let primary = Geist.gray1000
        /// Symbol icons in rows.
        static let secondary = Geist.gray800
    }

    enum Border {
        /// Dividers and outlines.
        static let hairline = Geist.grayAlpha400
    }

    enum Focus {
        static let ring = Geist.gray1000
    }

    enum Status {
        static let error = Geist.red900
        static let warning = Geist.amber900
        static let success = Geist.green900
    }
}
