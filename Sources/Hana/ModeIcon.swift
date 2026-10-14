import AppKit
import QuartzCore

/// One frame of the mode icon: a stroked outline, a ring and four spokes, each
/// drawn by its own shape layer. Every morph keeps these parts and their path
/// structure, so Core Animation can interpolate between frames.
struct ModeIconShape {
    struct Part {
        var path: CGPath
        var opacity: Float
    }

    /// The bloom outline, or the shape it morphs into.
    var bloom: Part
    var ring: Part
    /// Top-left, top-right, bottom-left, bottom-right.
    var spokes: [Part]
}

/// The Hana logo's geometry in its 28-point SVG space, y down, shared by every morph.
enum LogoGeometry {
    static let root2 = CGFloat(2).squareRoot()
    static let centre: CGFloat = 14
    static let lobeRadius: CGFloat = 7.467
    static let lobeDistance = 5.6 * root2
    static let ringRadius: CGFloat = 2.61
    static let spokeEnd = (14 - 9.968) * root2
    /// Spoke directions: top-left, top-right, bottom-left, bottom-right.
    static let directions = [(-1, -1), (1, -1), (-1, 1), (1, 1)].map {
        CGVector(dx: CGFloat($0.0) / root2, dy: CGFloat($0.1) / root2)
    }
    /// Angles the bloom outline is sampled at, from the top, clockwise on screen.
    /// 192 is a multiple of eight, so samples land exactly on its cusps and on
    /// the side midpoints of the Note icon's square.
    static let outlineAngles: [CGFloat] = (0..<192).map { -CGFloat.pi / 2 + 2 * .pi * CGFloat($0) / 192 }
    /// The bloom outline as a polyline, the outer edge of four circles.
    static let bloomPoints: [CGPoint] = outlineAngles.map { angle in
        var radius: CGFloat = 0
        for lobe in [1, 3, 5, 7] {
            let offset = angle - CGFloat(lobe) * .pi / 4
            let across = lobeDistance * sin(offset), reach = lobeRadius * lobeRadius - across * across
            if reach >= 0 { radius = max(radius, lobeDistance * cos(offset) + reach.squareRoot()) }
        }
        return CGPoint(x: centre + radius * cos(angle), y: centre + radius * sin(angle))
    }

    static func point(_ distance: CGFloat, along direction: CGVector) -> CGPoint {
        CGPoint(x: centre + distance * direction.dx, y: centre + distance * direction.dy)
    }

    static func line(_ start: CGPoint, _ end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    static func circle(_ centre: CGPoint, _ radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius),
               transform: nil)
    }
}

/// Search's mode icon: the Hana logo while the query is empty, a magnifying glass
/// once it has text. Tuned in prototypes/logo-morph ("Centre → lens"): the centre
/// ring grows into the lens, its bottom-right spoke becomes the handle, the other
/// spokes retract and the bloom releases outward and fades.
enum SearchIconMorph {
    /// Shared by the logo and the magnifier; the shipped logo SVG is 1.867.
    static let stroke: CGFloat = 2
    static let spring = Spring(duration: 0.24, bounce: 0.4)

    private typealias Logo = LogoGeometry
    /// The magnifier is drawn 1.2× about its own visual centre.
    private static let searchScale: CGFloat = 1.2
    private static func scaled(_ value: CGFloat) -> CGFloat { 14.1 + (value - 14.1) * searchScale }
    static let lensCentre = CGPoint(x: scaled(12.2), y: scaled(12.2))
    static let lensRadius = 7 * searchScale
    static let handleEnd = CGPoint(x: scaled(23), y: scaled(23))

    /// The icon at progress `p`: 0 is the logo, 1 the magnifier. A spring may
    /// overshoot either end; geometry follows it, opacity is clamped.
    static func shape(at p: CGFloat) -> ModeIconShape {
        let q = min(1, max(0, p)), overshoot = p - q
        func progress(_ start: CGFloat, _ end: CGFloat) -> CGFloat { min(1, max(0, (q - start) / (end - start))) }
        func window(_ start: CGFloat, _ end: CGFloat) -> CGFloat { progress(start, end) + overshoot }
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

        let grow = window(0, 1)
        let ring = CGPoint(x: lerp(Logo.centre, lensCentre.x, grow), y: lerp(Logo.centre, lensCentre.y, grow))
        let radius = max(0, lerp(Logo.ringRadius, lensRadius, grow))

        let release = progress(0, 0.6), bloomScale = lerp(1, 1.12, release)
        let bloom = Logo.bloomPoints.map {
            CGPoint(x: Logo.centre + ($0.x - Logo.centre) * bloomScale, y: Logo.centre + ($0.y - Logo.centre) * bloomScale)
        }

        let spokes = Logo.directions.enumerated().map { index, direction -> ModeIconShape.Part in
            let start = CGPoint(x: ring.x + radius * direction.dx, y: ring.y + radius * direction.dy)
            let end: CGPoint, opacity: CGFloat
            if index == Logo.directions.count - 1 {
                let cap = Logo.point(Logo.spokeEnd, along: direction)
                end = CGPoint(x: lerp(cap.x, handleEnd.x, grow), y: lerp(cap.y, handleEnd.y, grow))
                opacity = 1
            } else {
                let length = lerp(Logo.spokeEnd - Logo.ringRadius, 0, window(0, 0.4))
                end = CGPoint(x: start.x + length * direction.dx, y: start.y + length * direction.dy)
                opacity = 1 - progress(0.15, 0.4)
            }
            return ModeIconShape.Part(path: Logo.line(start, end), opacity: Float(opacity))
        }

        return ModeIconShape(bloom: ModeIconShape.Part(path: Logo.polygon(bloom), opacity: Float(1 - release)),
                             ring: ModeIconShape.Part(path: Logo.circle(ring, radius), opacity: 1),
                             spokes: spokes)
    }
}

/// Note's mode icon, morphing from the logo. Tuned in prototypes/logo-note-morph
/// ("Swing"): the bloom fills out into a rounded square, the top-left and
/// bottom-left spokes swing flat about their caps into the note's two text lines,
/// the ring shrinks away and the other two spokes retract into it. The outline
/// has its own, less bouncy spring, so the square settles while the lines spring.
enum NoteIconMorph {
    /// Drives the ring, spokes and text lines.
    static let spring = Spring(duration: 0.24, bounce: 0.4)
    static let outlineSpring = Spring(duration: 0.24, bounce: 0.3)

    private typealias Logo = LogoGeometry
    /// The Figma "Note Icon" frame (Test, node 32:67) is exported at 375 units
    /// with the 350-unit frame inset by 12.5, and draws the logo 15/14 the size of
    /// HanaLogo.svg. This maps its units into the logo's space.
    private static func figma(_ value: CGFloat) -> CGFloat { 14 + (value - 187.5) * 0.08 * 14 / 15 }
    /// The rounded square shares the bloom's extent and its lobe radius, so the
    /// lobe tips already sit on its corners and only the notches move.
    static let squareHalfWidth = figma(362.5) - 14
    static let cornerRadius = figma(112.5) - figma(12.5)
    static let topLine = (start: CGPoint(x: figma(133.5), y: figma(157)), end: CGPoint(x: figma(240.5), y: figma(157)))
    static let bottomLine = (start: CGPoint(x: figma(133.5), y: figma(217.5)), end: CGPoint(x: figma(187.5), y: figma(217.5)))
    /// Figma's spokes start here, under the ring at rest.
    private static let spokeStart = (14 - figma(156.5)) * Logo.root2

    /// The square sampled at the bloom's angles, so the two morph point for point.
    static let squarePoints: [CGPoint] = Logo.outlineAngles.map { angle in
        let c = abs(cos(angle)), s = abs(sin(angle)), flat = squareHalfWidth - cornerRadius
        var low: CGFloat = 0, high = 2 * squareHalfWidth
        for _ in 0..<40 {
            let mid = (low + high) / 2
            let dx = max(c * mid - flat, 0), dy = max(s * mid - flat, 0)
            if (dx * dx + dy * dy).squareRoot() <= cornerRadius { low = mid } else { high = mid }
        }
        return CGPoint(x: Logo.centre + low * cos(angle), y: Logo.centre + low * sin(angle))
    }

    /// The icon with the centre at progress `p` and the outline at `outline`:
    /// 0 is the logo, 1 the Note icon. Springs may overshoot either end; geometry
    /// follows them, opacity is clamped.
    static func shape(at p: CGFloat, outline: CGFloat) -> ModeIconShape {
        let q = min(1, max(0, p)), overshoot = p - q
        func progress(_ start: CGFloat, _ end: CGFloat) -> CGFloat { min(1, max(0, (q - start) / (end - start))) }
        func window(_ start: CGFloat, _ end: CGFloat) -> CGFloat { progress(start, end) + overshoot }
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }

        let bloom = zip(Logo.bloomPoints, squarePoints).map { mix($0, $1, outline) }

        let retract = lerp(Logo.spokeEnd - spokeStart, 0, window(0, 0.45)), retractedOpacity = 1 - progress(0.1, 0.4)
        let spokes = Logo.directions.enumerated().map { index, direction -> ModeIconShape.Part in
            let inner = Logo.point(spokeStart, along: direction)
            let target: (start: CGPoint, end: CGPoint)
            switch index {
            case 0: target = topLine
            case 2: target = bottomLine
            default:
                return ModeIconShape.Part(path: Logo.line(inner, Logo.point(spokeStart + retract, along: direction)),
                                          opacity: Float(retractedOpacity))
            }
            // Swing about the cap: it slides onto the line's start while the
            // spoke turns flat and stretches to the line's length.
            let cap = Logo.point(Logo.spokeEnd, along: direction)
            let start = mix(cap, target.start, p)
            let angle = lerp(atan2(inner.y - cap.y, inner.x - cap.x), 0, p)
            let length = lerp(Logo.spokeEnd - spokeStart, target.end.x - target.start.x, p)
            return ModeIconShape.Part(path: Logo.line(start, CGPoint(x: start.x + length * cos(angle), y: start.y + length * sin(angle))),
                                      opacity: 1)
        }

        let radius = max(0.01, lerp(Logo.ringRadius, Logo.ringRadius * 0.4, window(0, 0.5)))
        return ModeIconShape(bloom: ModeIconShape.Part(path: Logo.polygon(bloom), opacity: 1),
                             ring: ModeIconShape.Part(path: Logo.circle(CGPoint(x: Logo.centre, y: Logo.centre), radius),
                                                      opacity: Float(1 - progress(0, 0.45))),
                             spokes: spokes)
    }
}

/// A unit-mass spring in Apple's (duration, bounce) terms, as in
/// `CASpringAnimation(perceptualDuration:bounce:)`. Solved analytically, so a
/// retarget can start from the exact current displacement and velocity.
struct Spring {
    let duration: Double
    let bounce: Double

    /// Displacement from the target and velocity, `t` seconds after starting at `x0`, `v0`.
    func state(x0: Double, v0: Double, t: Double) -> (x: Double, v: Double) {
        let omega = 2 * .pi / duration, zeta = 1 - min(1, max(0, bounce))
        if zeta < 1 {
            let damped = omega * (1 - zeta * zeta).squareRoot(), decay = exp(-zeta * omega * t)
            let a = x0, b = (v0 + zeta * omega * x0) / damped
            let c = cos(damped * t), s = sin(damped * t)
            return (decay * (a * c + b * s),
                    decay * ((b * damped - zeta * omega * a) * c - (a * damped + zeta * omega * b) * s))
        }
        let decay = exp(-omega * t), b = v0 + omega * x0
        return (decay * (x0 + b * t), decay * (v0 - omega * b * t))
    }

    /// When the motion is visually at rest.
    func settlingTime(x0: Double, v0: Double) -> Double {
        var t = 0.0
        while t < 2 {
            let state = state(x0: x0, v0: v0, t: t)
            if abs(state.x) < 1e-3, abs(state.v) < 1e-2 { return t }
            t += 1.0 / 240
        }
        return t
    }
}

/// Draws the mode icon with one shape layer per part. Each change is sampled
/// from its springs into keyframes that run on the render server, so a busy main
/// actor (results arriving on the first keystroke) cannot drop frames.
@MainActor
final class ModeIconView: NSView {
    enum Glyph {
        case logo, magnifier, note
    }

    private(set) var glyph = Glyph.logo
    var showsQuery: Bool { glyph == .magnifier }
    /// Whether a spring morph is running, rather than a crossfade or nothing.
    var isMorphing: Bool { motion.map { CACurrentMediaTime() - $0.start < $0.duration } ?? false }
    private let canvas = CALayer()
    private let bloom = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let spokes = (0..<4).map { _ in CAShapeLayer() }
    private var parts: [CAShapeLayer] { [bloom, ring] + spokes }
    private var motion: Motion?

    /// The morphs out of the logo: progress 0 is the logo in both.
    private enum Morph {
        case search, note

        var springs: (centre: Spring, outline: Spring) {
            switch self {
            case .search: (SearchIconMorph.spring, SearchIconMorph.spring)
            case .note: (NoteIconMorph.spring, NoteIconMorph.outlineSpring)
            }
        }

        func shape(centre: Double, outline: Double) -> ModeIconShape {
            switch self {
            case .search: SearchIconMorph.shape(at: centre)
            case .note: NoteIconMorph.shape(at: centre, outline: outline)
            }
        }
    }

    /// Where the icon is within a morph: progress and velocity for each spring.
    private struct Position {
        var morph: Morph?
        var centre: (p: Double, v: Double)
        var outline: (p: Double, v: Double)
    }

    private struct Motion {
        let morph: Morph
        let start: CFTimeInterval
        let centre: (x0: Double, v0: Double)
        let outline: (x0: Double, v0: Double)
        let target: Double
        let duration: Double
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
        canvas.bounds = CGRect(x: 0, y: 0, width: 28, height: 28)
        // The geometry is in SVG space, y down.
        canvas.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1))
        layer?.addSublayer(canvas)
        for part in parts {
            part.fillColor = nil
            part.strokeColor = BarStyle.modeIconColor.cgColor
            part.lineWidth = SearchIconMorph.stroke
            part.lineCap = .round
            part.lineJoin = .round
            canvas.addSublayer(part)
        }
        apply(SearchIconMorph.shape(at: 0))
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for part in [canvas] + parts { part.contentsScale = scale }
    }

    func setShowsQuery(_ shows: Bool, animated: Bool) {
        setGlyph(shows ? .magnifier : .logo, animated: animated)
    }

    /// Retargets from wherever the icon is, keeping its velocity, so deleting the
    /// first character mid-morph reverses smoothly. The magnifier and the Note
    /// icon only morph to and from the logo; between them the icon crossfades.
    func setGlyph(_ next: Glyph, animated: Bool) {
        guard next != glyph else { return }
        let now = CACurrentMediaTime()
        let current = position(at: now)
        glyph = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for layer in [canvas] + parts { layer.removeAllAnimations() }
        motion = nil

        let morph: Morph = switch next {
        case .magnifier: .search
        case .note: .note
        case .logo: current.morph ?? .search
        }
        let target: Double = next == .logo ? 0 : 1
        let settled = morph.shape(centre: target, outline: target)
        guard animated else { return apply(settled) }
        let continuous = current.morph == nil || current.morph == morph
        if !continuous || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            canvas.add(fade, forKey: "fade")
            return apply(settled)
        }

        let springs = morph.springs
        let centre = (x0: current.centre.p - target, v0: current.centre.v)
        let outline = (x0: current.outline.p - target, v0: current.outline.v)
        let duration = max(springs.centre.settlingTime(x0: centre.x0, v0: centre.v0),
                           springs.outline.settlingTime(x0: outline.x0, v0: outline.v0))
        motion = Motion(morph: morph, start: now, centre: centre, outline: outline, target: target, duration: duration)
        let count = max(2, Int((duration * 120).rounded(.up)))
        let shapes = (0...count).map { index -> ModeIconShape in
            guard index < count else { return settled }
            let t = duration * Double(index) / Double(count)
            return morph.shape(centre: target + springs.centre.state(x0: centre.x0, v0: centre.v0, t: t).x,
                               outline: target + springs.outline.state(x0: outline.x0, v0: outline.v0, t: t).x)
        }
        let keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        func animate(_ layer: CALayer, _ keyPath: String, _ values: [Any]) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = keyTimes
            animation.calculationMode = .linear
            animation.duration = duration
            animation.beginTime = layer.convertTime(now, from: nil)
            animation.fillMode = .backwards
            layer.add(animation, forKey: keyPath)
        }
        animate(bloom, "path", shapes.map(\.bloom.path))
        animate(bloom, "opacity", shapes.map(\.bloom.opacity))
        animate(ring, "path", shapes.map(\.ring.path))
        animate(ring, "opacity", shapes.map(\.ring.opacity))
        for (index, spoke) in spokes.enumerated() {
            animate(spoke, "path", shapes.map { $0.spokes[index].path })
            animate(spoke, "opacity", shapes.map { $0.spokes[index].opacity })
        }
        apply(settled)
    }

    /// At rest, the magnifier and the Note icon belong to their own morph; the
    /// logo, at progress 0, belongs to either.
    private func position(at now: CFTimeInterval) -> Position {
        if let motion, now - motion.start < motion.duration {
            let springs = motion.morph.springs, t = now - motion.start
            let centre = springs.centre.state(x0: motion.centre.x0, v0: motion.centre.v0, t: t)
            let outline = springs.outline.state(x0: motion.outline.x0, v0: motion.outline.v0, t: t)
            return Position(morph: motion.morph,
                            centre: (motion.target + centre.x, centre.v),
                            outline: (motion.target + outline.x, outline.v))
        }
        return switch glyph {
        case .logo: Position(morph: nil, centre: (0, 0), outline: (0, 0))
        case .magnifier: Position(morph: .search, centre: (1, 0), outline: (1, 0))
        case .note: Position(morph: .note, centre: (1, 0), outline: (1, 0))
        }
    }

    private func apply(_ shape: ModeIconShape) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bloom.path = shape.bloom.path
        bloom.opacity = shape.bloom.opacity
        ring.path = shape.ring.path
        ring.opacity = shape.ring.opacity
        for (spoke, part) in zip(spokes, shape.spokes) {
            spoke.path = part.path
            spoke.opacity = part.opacity
        }
        CATransaction.commit()
    }
}
