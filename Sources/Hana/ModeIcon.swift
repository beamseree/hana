import AppKit
import QuartzCore

/// Search's mode icon: the Hana logo while the query is empty, a magnifying glass
/// once it has text. Tuned in prototypes/logo-morph ("Centre → lens"): the centre
/// ring grows into the lens, its bottom-right spoke becomes the handle, the other
/// spokes retract and the bloom releases outward and fades.
enum SearchIconMorph {
    struct Part {
        var path: CGPath
        var opacity: Float
    }

    struct Shape {
        var bloom: Part
        var ring: Part
        var spokes: [Part]
    }

    /// Shared by the logo and the magnifier; the shipped logo SVG is 1.867.
    static let stroke: CGFloat = 2
    static let spring = Spring(duration: 0.24, bounce: 0.4)

    // Geometry in the logo's 28-point SVG space, y down.
    private static let root2 = CGFloat(2).squareRoot()
    private static let centre: CGFloat = 14
    private static let lobeRadius: CGFloat = 7.467
    private static let lobeDistance = 5.6 * root2
    private static let ringRadius: CGFloat = 2.61
    private static let spokeEnd = (14 - 9.968) * root2
    /// The magnifier is drawn 1.2× about its own visual centre.
    private static let searchScale: CGFloat = 1.2
    private static func scaled(_ value: CGFloat) -> CGFloat { 14.1 + (value - 14.1) * searchScale }
    static let lensCentre = CGPoint(x: scaled(12.2), y: scaled(12.2))
    static let lensRadius = 7 * searchScale
    static let handleEnd = CGPoint(x: scaled(23), y: scaled(23))
    /// Spoke directions; the last, bottom-right, becomes the handle.
    private static let directions = [(-1, -1), (1, -1), (-1, 1), (1, 1)].map {
        CGVector(dx: CGFloat($0.0) / root2, dy: CGFloat($0.1) / root2)
    }
    /// The bloom outline as a polyline, the outer edge of four circles. 192 is a
    /// multiple of four, so samples land exactly on its cusps.
    private static let bloomPoints: [CGPoint] = (0..<192).map { index in
        let angle = -CGFloat.pi / 2 + 2 * .pi * CGFloat(index) / 192
        var radius: CGFloat = 0
        for lobe in [1, 3, 5, 7] {
            let offset = angle - CGFloat(lobe) * .pi / 4
            let across = lobeDistance * sin(offset), reach = lobeRadius * lobeRadius - across * across
            if reach >= 0 { radius = max(radius, lobeDistance * cos(offset) + reach.squareRoot()) }
        }
        return CGPoint(x: centre + radius * cos(angle), y: centre + radius * sin(angle))
    }

    /// The icon at progress `p`: 0 is the logo, 1 the magnifier. A spring may
    /// overshoot either end; geometry follows it, opacity is clamped.
    static func shape(at p: CGFloat) -> Shape {
        let q = min(1, max(0, p)), overshoot = p - q
        func progress(_ start: CGFloat, _ end: CGFloat) -> CGFloat { min(1, max(0, (q - start) / (end - start))) }
        func window(_ start: CGFloat, _ end: CGFloat) -> CGFloat { progress(start, end) + overshoot }
        func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

        let grow = window(0, 1)
        let ring = CGPoint(x: lerp(centre, lensCentre.x, grow), y: lerp(centre, lensCentre.y, grow))
        let radius = max(0, lerp(ringRadius, lensRadius, grow))
        let ringPath = CGPath(ellipseIn: CGRect(x: ring.x - radius, y: ring.y - radius, width: 2 * radius, height: 2 * radius),
                              transform: nil)

        let release = progress(0, 0.6), bloomScale = lerp(1, 1.12, release)
        let bloomPath = CGMutablePath()
        bloomPath.addLines(between: bloomPoints.map {
            CGPoint(x: centre + ($0.x - centre) * bloomScale, y: centre + ($0.y - centre) * bloomScale)
        })
        bloomPath.closeSubpath()

        let spokes = directions.enumerated().map { index, direction -> Part in
            let start = CGPoint(x: ring.x + radius * direction.dx, y: ring.y + radius * direction.dy)
            let end: CGPoint, opacity: CGFloat
            if index == directions.count - 1 {
                end = CGPoint(x: lerp(centre + spokeEnd * direction.dx, handleEnd.x, grow),
                              y: lerp(centre + spokeEnd * direction.dy, handleEnd.y, grow))
                opacity = 1
            } else {
                let length = lerp(spokeEnd - ringRadius, 0, window(0, 0.4))
                end = CGPoint(x: start.x + length * direction.dx, y: start.y + length * direction.dy)
                opacity = 1 - progress(0.15, 0.4)
            }
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: end)
            return Part(path: path, opacity: Float(opacity))
        }

        return Shape(bloom: Part(path: bloomPath, opacity: Float(1 - release)),
                     ring: Part(path: ringPath, opacity: 1),
                     spokes: spokes)
    }
}

/// Note's mode icon, App/Resources/NoteIcon.svg: the logo's bloom around two
/// lines of text, in the same 28-point SVG space.
enum NoteIcon {
    static var lines: CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 9.933, y: 11.6))
        path.addLine(to: CGPoint(x: 18.067, y: 11.6))
        path.move(to: CGPoint(x: 9.933, y: 16.4))
        path.addLine(to: CGPoint(x: 14.8, y: 16.4))
        return path
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

/// Draws `SearchIconMorph` or the note icon, one shape layer per part. Each
/// change is sampled from the spring into keyframes that run on the render
/// server, so a busy main actor (results arriving on the first keystroke)
/// cannot drop frames.
@MainActor
final class ModeIconView: NSView {
    private(set) var showsQuery = false
    private(set) var showsNote = false
    private let canvas = CALayer()
    private let bloom = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let spokes = (0..<4).map { _ in CAShapeLayer() }
    private let noteLines = CAShapeLayer()
    private var parts: [CAShapeLayer] { [bloom, ring] + spokes + [noteLines] }
    private var motion: Motion?

    private struct Motion {
        let start: CFTimeInterval
        let x0: Double
        let v0: Double
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
        noteLines.path = NoteIcon.lines
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

    /// Retargets from wherever the icon is, keeping its velocity, so deleting the
    /// first character mid-morph reverses smoothly.
    func setShowsQuery(_ shows: Bool, animated: Bool) {
        guard shows != showsQuery else { return }
        // Note's icon does not follow the query.
        guard !showsNote else { showsQuery = shows; return }
        let now = CACurrentMediaTime()
        let current = progress(at: now)
        showsQuery = shows
        let target: Double = shows ? 1 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for layer in [canvas] + parts { layer.removeAllAnimations() }
        motion = nil

        guard animated else { return apply(SearchIconMorph.shape(at: target)) }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            canvas.add(fade, forKey: "fade")
            return apply(SearchIconMorph.shape(at: target))
        }

        let spring = SearchIconMorph.spring
        let x0 = current.p - target, v0 = current.v
        let duration = spring.settlingTime(x0: x0, v0: v0)
        motion = Motion(start: now, x0: x0, v0: v0, target: target, duration: duration)
        let count = max(2, Int((duration * 120).rounded(.up)))
        let shapes = (0...count).map { index in
            index == count ? SearchIconMorph.shape(at: target)
                : SearchIconMorph.shape(at: target + spring.state(x0: x0, v0: v0, t: duration * Double(index) / Double(count)).x)
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
        for (index, spoke) in spokes.enumerated() {
            animate(spoke, "path", shapes.map { $0.spokes[index].path })
            animate(spoke, "opacity", shapes.map { $0.spokes[index].opacity })
        }
        apply(shapes[count])
    }

    /// Cross-fades between the note icon and Search's current icon.
    func setShowsNote(_ shows: Bool, animated: Bool) {
        guard shows != showsNote else { return }
        showsNote = shows
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for layer in [canvas] + parts { layer.removeAllAnimations() }
        motion = nil
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = BarStyle.resizeDuration
            canvas.add(fade, forKey: "fade")
        }
        apply(SearchIconMorph.shape(at: shows ? 0 : showsQuery ? 1 : 0))
    }

    private func progress(at now: CFTimeInterval) -> (p: Double, v: Double) {
        guard let motion, now - motion.start < motion.duration else { return (showsQuery ? 1 : 0, 0) }
        let state = SearchIconMorph.spring.state(x0: motion.x0, v0: motion.v0, t: now - motion.start)
        return (motion.target + state.x, state.v)
    }

    private func apply(_ shape: SearchIconMorph.Shape) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Note keeps the logo's bloom and replaces its centre with lines.
        bloom.path = shape.bloom.path
        bloom.opacity = shape.bloom.opacity
        ring.path = shape.ring.path
        ring.opacity = showsNote ? 0 : shape.ring.opacity
        for (spoke, part) in zip(spokes, shape.spokes) {
            spoke.path = part.path
            spoke.opacity = showsNote ? 0 : part.opacity
        }
        noteLines.opacity = showsNote ? 1 : 0
        CATransaction.commit()
    }
}
