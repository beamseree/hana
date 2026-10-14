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

    /// Note's icon is the shipped asset: its text lines, inside the logo's bloom.
    @Test func noteLinesMatchTheNoteIconAsset() throws {
        let asset = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/NoteIcon.svg")
        let svg = try String(contentsOf: asset, encoding: .utf8)
        let lines = try #require(svg.firstMatch(of: /id="Lines" d="([^"]+)"/)?.1)
        // "M x y H x" segments, as the asset writes them.
        let expected = lines.matches(of: /M([\d.]+) ([\d.]+)H([\d.]+)/).flatMap { match in
            [CGPoint(x: Double(match.1)!, y: Double(match.2)!), CGPoint(x: Double(match.3)!, y: Double(match.2)!)]
        }
        var drawn: [CGPoint] = []
        NoteIcon.lines.applyWithBlock { drawn.append($0.pointee.points[0]) }
        #expect(expected.count == 4)
        #expect(drawn == expected)
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
