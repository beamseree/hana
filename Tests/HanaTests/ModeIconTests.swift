import AppKit
import Testing
@testable import Hana

/// Geometry and timing of Search's logo-to-magnifier morph. Visual tuning lives
/// in prototypes/logo-morph; these checks pin its end states and continuity.
struct SearchIconMorphTests {
    @Test func restingShapeIsTheLogo() {
        let logo = SearchIconMorph.shape(at: 0)
        let ring = logo.ring.path.boundingBoxOfPath
        #expect(abs(ring.midX - 14) < 0.001 && abs(ring.midY - 14) < 0.001)
        #expect(abs(ring.width / 2 - 2.61) < 0.001)
        #expect(logo.bloom.opacity == 1 && logo.spokes.allSatisfy { $0.opacity == 1 })
        // The bloom's lobes reach the logo's edges.
        let bloom = logo.bloom.path.boundingBoxOfPath
        #expect(abs(bloom.minX - (8.4 - 7.467)) < 0.01 && abs(bloom.maxY - (19.6 + 7.467)) < 0.01)
    }

    @Test func settledShapeIsTheMagnifier() {
        let search = SearchIconMorph.shape(at: 1)
        let ring = search.ring.path.boundingBoxOfPath
        #expect(abs(ring.midX - SearchIconMorph.lensCentre.x) < 0.001)
        #expect(abs(ring.width / 2 - SearchIconMorph.lensRadius) < 0.001)
        #expect(search.bloom.opacity == 0)
        #expect(search.spokes.dropLast().allSatisfy { $0.opacity == 0 })
        let handle = search.spokes[3].path.boundingBoxOfPath
        let edge = SearchIconMorph.lensCentre.x + SearchIconMorph.lensRadius / CGFloat(2).squareRoot()
        #expect(abs(handle.minX - edge) < 0.001)
        #expect(abs(handle.maxX - SearchIconMorph.handleEnd.x) < 0.001)
        #expect(search.spokes[3].opacity == 1)
    }

    @Test func magnifierStaysInsideTheIconGutter() {
        let search = SearchIconMorph.shape(at: 1)
        let bounds = search.spokes.reduce(search.ring.path.boundingBoxOfPath) { $0.union($1.path.boundingBoxOfPath) }
            .insetBy(dx: -SearchIconMorph.stroke / 2, dy: -SearchIconMorph.stroke / 2)
        #expect(CGRect(x: 0, y: 0, width: 28, height: 28).contains(bounds))
    }

    @Test func springStartsWhereItIsAndSettlesOnTarget() {
        let spring = SearchIconMorph.spring
        let start = spring.state(x0: -1, v0: 0, t: 0)
        #expect(abs(start.x + 1) < 1e-9 && abs(start.v) < 1e-9)
        let settle = spring.settlingTime(x0: -1, v0: 0)
        #expect(settle > 0.2 && settle < 1)
        #expect(abs(spring.state(x0: -1, v0: 0, t: settle).x) < 1e-3)
        // Bounce 0.4 overshoots the magnifier slightly before settling.
        let peak = stride(from: 0.0, to: settle, by: 0.001).map { spring.state(x0: -1, v0: 0, t: $0).x }.max() ?? 0
        #expect(peak > 0.05 && peak < 0.15)
    }

    @Test func reportedVelocityMatchesMotion() {
        let spring = Spring(duration: 0.24, bounce: 0.4), dt = 1e-6
        for t in [0.02, 0.08, 0.15] {
            let numeric = (spring.state(x0: -1, v0: 3, t: t + dt).x - spring.state(x0: -1, v0: 3, t: t - dt).x) / (2 * dt)
            #expect(abs(numeric - spring.state(x0: -1, v0: 3, t: t).v) < 1e-3)
        }
        let critical = Spring(duration: 0.24, bounce: 0)
        let numeric = (critical.state(x0: -1, v0: 3, t: 0.05 + dt).x - critical.state(x0: -1, v0: 3, t: 0.05 - dt).x) / (2 * dt)
        #expect(abs(numeric - critical.state(x0: -1, v0: 3, t: 0.05).v) < 1e-3)
    }
}

/// Geometry and timing of the logo-to-Note morph. Visual tuning lives in
/// prototypes/logo-note-morph; the end state is the Figma "Note Icon" frame.
struct NoteIconMorphTests {
    /// Figma export units (375-unit frame) in the logo's 28-point space.
    private func figma(_ value: CGFloat) -> CGFloat { 14 + (value - 187.5) * 0.08 * 14 / 15 }

    @Test func restingShapeIsTheLogo() {
        let note = NoteIconMorph.shape(at: 0, outline: 0), logo = SearchIconMorph.shape(at: 0)
        #expect(note.bloom.path.boundingBoxOfPath == logo.bloom.path.boundingBoxOfPath)
        #expect(note.ring.path.boundingBoxOfPath == logo.ring.path.boundingBoxOfPath)
        #expect(note.bloom.opacity == 1 && note.ring.opacity == 1 && note.spokes.allSatisfy { $0.opacity == 1 })
        // Every spoke ends on the logo's cap and lies on its diagonal.
        for (spoke, logoSpoke) in zip(note.spokes, logo.spokes) {
            let box = spoke.path.boundingBoxOfPath, logoBox = logoSpoke.path.boundingBoxOfPath
            #expect(abs(box.width - box.height) < 0.001)
            #expect(abs(min(box.minX, 28 - box.maxX) - min(logoBox.minX, 28 - logoBox.maxX)) < 0.001)
        }
    }

    @Test func settledShapeIsTheFigmaNoteIcon() {
        let note = NoteIconMorph.shape(at: 1, outline: 1)
        let top = note.spokes[0].path.boundingBoxOfPath, bottom = note.spokes[2].path.boundingBoxOfPath
        #expect(abs(top.minX - figma(133.5)) < 0.001 && abs(top.maxX - figma(240.5)) < 0.001)
        #expect(abs(top.midY - figma(157)) < 0.001 && top.height < 0.001)
        #expect(abs(bottom.minX - figma(133.5)) < 0.001 && abs(bottom.maxX - figma(187.5)) < 0.001)
        #expect(abs(bottom.midY - figma(217.5)) < 0.001 && bottom.height < 0.001)
        #expect(note.spokes[0].opacity == 1 && note.spokes[2].opacity == 1)
        #expect(note.ring.opacity == 0 && note.spokes[1].opacity == 0 && note.spokes[3].opacity == 0)
        // The rounded square keeps the bloom's footprint: flat sides at its
        // extent, corners on its lobe tips.
        let square = NoteIconMorph.squarePoints
        #expect(note.bloom.opacity == 1)
        #expect(note.bloom.path.boundingBoxOfPath.insetBy(dx: -0.001, dy: -0.001)
            .contains(SearchIconMorph.shape(at: 0).bloom.path.boundingBoxOfPath))
        #expect(abs(square[0].y - figma(12.5)) < 0.001 && abs(square[0].x - 14) < 0.001)
        let corner = square[24], lobeTip = LogoGeometry.bloomPoints[24]
        #expect(abs(corner.x - lobeTip.x) < 0.01 && abs(corner.y - lobeTip.y) < 0.01)
    }

    @Test func outlineFollowsItsOwnProgress() {
        let shape = NoteIconMorph.shape(at: 0, outline: 1)
        #expect(shape.bloom.path.boundingBoxOfPath == NoteIconMorph.shape(at: 1, outline: 1).bloom.path.boundingBoxOfPath)
        #expect(shape.ring.opacity == 1 && shape.spokes.allSatisfy { $0.opacity == 1 })
    }

    @Test func everyFrameKeepsThePathStructure() {
        func elements(_ path: CGPath) -> [CGPathElementType] {
            var types: [CGPathElementType] = []
            path.applyWithBlock { types.append($0.pointee.type) }
            return types
        }
        func structure(_ shape: ModeIconShape) -> [[CGPathElementType]] {
            ([shape.bloom, shape.ring] + shape.spokes).map { elements($0.path) }
        }
        let rest = structure(SearchIconMorph.shape(at: 0))
        for p in stride(from: -0.1, through: 1.1, by: 0.1) {
            #expect(structure(NoteIconMorph.shape(at: p, outline: p)) == rest)
        }
    }

    @Test func outlineBouncesLessThanTheLines() {
        func peak(_ spring: Spring) -> Double {
            stride(from: 0.0, to: 1, by: 0.001).map { spring.state(x0: -1, v0: 0, t: $0).x }.max() ?? 0
        }
        let lines = peak(NoteIconMorph.spring), outline = peak(NoteIconMorph.outlineSpring)
        #expect(outline > 0.01 && outline < lines)
    }
}

/// Geometry and timing of the logo-to-Task morph. Visual tuning lives in
/// prototypes/logo-task-morph; the end state is a circle with a checkmark.
struct TaskIconMorphTests {
    /// A line path's two points, in drawing order.
    private func ends(_ path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.applyWithBlock { points.append($0.pointee.points[0]) }
        return points
    }

    @Test func restingShapeIsTheLogo() {
        let task = TaskIconMorph.shape(at: 0, outline: 0), note = NoteIconMorph.shape(at: 0, outline: 0)
        #expect(task.bloom.path.boundingBoxOfPath == note.bloom.path.boundingBoxOfPath)
        #expect(task.ring.path.boundingBoxOfPath == note.ring.path.boundingBoxOfPath)
        #expect(task.bloom.opacity == 1 && task.ring.opacity == 1 && task.spokes.allSatisfy { $0.opacity == 1 })
        for (spoke, noteSpoke) in zip(task.spokes, note.spokes) {
            #expect(spoke.path.boundingBoxOfPath == noteSpoke.path.boundingBoxOfPath)
        }
    }

    @Test func settledShapeIsACircleWithACheckmark() {
        let task = TaskIconMorph.shape(at: 1, outline: 1), check = TaskIconMorph.check
        func runs(_ part: ModeIconShape.Part, _ from: CGPoint, _ to: CGPoint) -> Bool {
            zip(ends(part.path), [from, to]).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.001 }
        }
        #expect(runs(task.spokes[0], check.start, check.corner))
        #expect(runs(task.spokes[1], check.corner, check.end))
        #expect(task.spokes[0].opacity == 1 && task.spokes[1].opacity == 1)
        #expect(task.ring.opacity == 0 && task.spokes[2].opacity == 0 && task.spokes[3].opacity == 0)
        // The arms run along the spoke diagonals, 4 and 8 points long, and the
        // check's bounding box is centred on the icon.
        let short = hypot(check.corner.x - check.start.x, check.corner.y - check.start.y)
        let long = hypot(check.end.x - check.corner.x, check.end.y - check.corner.y)
        #expect(abs(short - 4) < 0.001 && abs(long - 8) < 0.001)
        #expect(abs((check.corner.x - check.start.x) - (check.corner.y - check.start.y)) < 0.001)
        #expect(abs((check.end.x - check.corner.x) + (check.end.y - check.corner.y)) < 0.001)
        #expect(abs((check.start.x + check.end.x) / 2 - 14) < 0.001)
        #expect(abs((check.end.y + check.corner.y) / 2 - 14) < 0.001)
        // The circle reaches the logo's edges, as the bloom's lobes do.
        let circle = task.bloom.path.boundingBoxOfPath
        #expect(task.bloom.opacity == 1)
        #expect(abs(circle.minX - (8.4 - 7.467)) < 0.001 && abs(circle.maxY - (19.6 + 7.467)) < 0.001)
        #expect(TaskIconMorph.circlePoints.allSatisfy { abs(hypot($0.x - 14, $0.y - 14) - TaskIconMorph.circleRadius) < 0.001 })
    }

    @Test func topSpokesSlideWithoutTurning() {
        for p in stride(from: -0.1, through: 1.1, by: 0.1) {
            let shape = TaskIconMorph.shape(at: p, outline: p)
            for (index, sign) in [(0, CGFloat(1)), (1, -1)] {
                let points = ends(shape.spokes[index].path)
                let dx = points[1].x - points[0].x, dy = points[1].y - points[0].y
                #expect(dx > 0 && abs(dy - sign * dx) < 0.001)
            }
        }
    }

    @Test func outlineFollowsItsOwnProgress() {
        let shape = TaskIconMorph.shape(at: 0, outline: 1)
        #expect(shape.bloom.path.boundingBoxOfPath == TaskIconMorph.shape(at: 1, outline: 1).bloom.path.boundingBoxOfPath)
        #expect(shape.ring.opacity == 1 && shape.spokes.allSatisfy { $0.opacity == 1 })
    }

    @Test func everyFrameKeepsThePathStructure() {
        func elements(_ path: CGPath) -> [CGPathElementType] {
            var types: [CGPathElementType] = []
            path.applyWithBlock { types.append($0.pointee.type) }
            return types
        }
        func structure(_ shape: ModeIconShape) -> [[CGPathElementType]] {
            ([shape.bloom, shape.ring] + shape.spokes).map { elements($0.path) }
        }
        let rest = structure(SearchIconMorph.shape(at: 0))
        for p in stride(from: -0.1, through: 1.1, by: 0.1) {
            #expect(structure(TaskIconMorph.shape(at: p, outline: p)) == rest)
        }
    }

    @Test func outlineBouncesMoreThanTheCheck() {
        func peak(_ spring: Spring) -> Double {
            stride(from: 0.0, to: 1, by: 0.001).map { spring.state(x0: -1, v0: 0, t: $0).x }.max() ?? 0
        }
        let check = peak(TaskIconMorph.spring), outline = peak(TaskIconMorph.outlineSpring)
        #expect(check > 0.01 && check < outline)
    }
}

@Suite(.serialized)
@MainActor
struct ModeIconViewTests {
    @Test func noteMorphsFromAndBackToTheLogoAndCrossfadesWithTheMagnifier() {
        let view = ModeIconView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        let morphs = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.setGlyph(.note, animated: true)
        #expect(view.glyph == .note && view.isMorphing == morphs)
        // Reversing mid-morph keeps morphing.
        view.setGlyph(.logo, animated: true)
        #expect(view.glyph == .logo && view.isMorphing == morphs)
        view.setGlyph(.note, animated: false)
        #expect(!view.isMorphing)
        // No morph is designed between the Note icon and the magnifier.
        view.setGlyph(.magnifier, animated: true)
        #expect(view.glyph == .magnifier && view.showsQuery && !view.isMorphing)
        view.setGlyph(.logo, animated: true)
        #expect(view.glyph == .logo && view.isMorphing == morphs)
    }

    @Test func taskMorphsFromAndBackToTheLogoAndCrossfadesWithTheOtherGlyphs() {
        let view = ModeIconView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        let morphs = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        view.setGlyph(.task, animated: true)
        #expect(view.glyph == .task && view.isMorphing == morphs)
        view.setGlyph(.logo, animated: true)
        #expect(view.glyph == .logo && view.isMorphing == morphs)
        view.setGlyph(.task, animated: false)
        #expect(!view.isMorphing)
        // No morph is designed between the Task icon and the other glyphs.
        view.setGlyph(.note, animated: true)
        #expect(view.glyph == .note && !view.isMorphing)
        view.setGlyph(.task, animated: true)
        #expect(view.glyph == .task && !view.isMorphing)
        view.setGlyph(.magnifier, animated: true)
        #expect(view.glyph == .magnifier && !view.isMorphing)
        view.setGlyph(.logo, animated: true)
        #expect(view.glyph == .logo && view.isMorphing == morphs)
    }
}

@Suite(.serialized)
@MainActor
struct ModeIconInteractionTests {
    @Test func queryTextShowsTheMagnifierAndClearingRestoresTheLogo() {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        #expect(!interaction.modeIconShowsQuery)
        interaction.updateQuery("s")
        #expect(interaction.modeIconShowsQuery)
        interaction.updateQuery("")
        #expect(!interaction.modeIconShowsQuery)
        interaction.updateQuery("safari")
        interaction.dismiss(invocation, reason: .escape)
        #expect(!interaction.modeIconShowsQuery)
        let next = interaction.presentBar()
        #expect(next != invocation && !interaction.modeIconShowsQuery)
    }
}
