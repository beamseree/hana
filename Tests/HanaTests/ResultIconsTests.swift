import AppKit
import Testing
@testable import Hana

/// Result Icons over real temporary `.app` bundles on disk.
@Suite(.timeLimit(.minutes(1)))
struct ResultIconsTests {
    @Test func customIconDiffersFromTheGenericApplicationIconAtTheRequestedPixelSize() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let red = try fixtureApp(in: root, named: "Red", color: .systemRed)
        let generic = try fixtureApp(in: root, named: "Generic", color: nil)
        let icons = ResultIcons(pointSize: 28)
        let icon = try #require(await icons.icon(for: red, scale: 2))
        #expect(icon.image.width == 56 && icon.image.height == 56)
        #expect(icon.scale == 2)
        let fallback = try #require(await icons.icon(for: generic, scale: 2))
        #expect(pixels(icon) != pixels(fallback))
    }

    @Test func installationsSharingABundleIdentifierKeepTheirOwnIcons() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "com.beamseree.hana.fixture.\(UUID().uuidString)"
        let release = try fixtureApp(in: root, named: "Fixture", color: .systemBlue, identifier: identifier)
        let beta = try fixtureApp(in: root, named: "Fixture Beta", color: .systemOrange, identifier: identifier)
        let icons = ResultIcons()
        let releaseIcon = await icons.icon(for: release, scale: 1)
        let betaIcon = await icons.icon(for: beta, scale: 1)
        #expect(releaseIcon != nil && betaIcon != nil)
        #expect(pixels(releaseIcon) != pixels(betaIcon))
    }

    @Test func missingDeletedOrUnreadableBundlesProduceNoIcon() async throws {
        let root = try fixtureRoot()
        let unreadable = try fixtureApp(in: root, named: "Locked", color: .systemGreen)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
            try? FileManager.default.removeItem(at: root)
        }
        let deleted = try fixtureApp(in: root, named: "Deleted", color: .systemPurple)
        let icons = ResultIcons()
        #expect(await icons.icon(for: deleted, scale: 2) != nil)
        try FileManager.default.removeItem(at: deleted)
        #expect(await icons.icon(for: deleted, scale: 2) == nil)
        #expect(await icons.icon(for: root.appendingPathComponent("Missing.app"), scale: 2) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        #expect(await icons.icon(for: unreadable, scale: 2) == nil)
    }

    @Test func anUpdatedBundleProducesItsNewIconWhileAnUnchangedOneIsServedFromCache() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try fixtureApp(in: root, named: "Updating", color: .systemRed)
        let icons = ResultIcons()
        let original = pixels(await icons.icon(for: bundle, scale: 2))
        #expect(original != nil)
        try writeIcon(.systemTeal, to: bundle)
        #expect(pixels(await icons.icon(for: bundle, scale: 2)) == original)
        // An update replaces the bundle; the system's own icon cache follows the bundle stamp.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: bundle.path)
        let updated = pixels(await icons.icon(for: bundle, scale: 2))
        #expect(updated != nil && updated != original)
    }

    @Test func theCacheStaysWithinItsCapAcrossManyDistinctInstallations() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let icons = ResultIcons(capacity: 4)
        for index in 0..<10 {
            let bundle = try fixtureApp(in: root, named: "App \(index)", color: .systemRed)
            #expect(await icons.icon(for: bundle, scale: 1) != nil)
            #expect(await icons.cachedCount <= 4)
        }
        #expect(await icons.cachedCount == 4)
    }
}

func fixtureRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A minimal bundle; a nil color omits the icon resource so macOS supplies its generic one.
@discardableResult
func fixtureApp(in root: URL, named name: String, color: NSColor?,
                identifier: String = "com.beamseree.hana.fixture.\(UUID().uuidString)") throws -> URL {
    let bundle = root.appendingPathComponent("\(name).app", isDirectory: true)
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundlePackageType": "APPL"]
    if let color {
        info["CFBundleIconFile"] = "AppIcon"
        try writeIcon(color, to: bundle)
    }
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return bundle
}

/// Replaces the bundle's icon resource without touching its change stamp.
func writeIcon(_ color: NSColor, to bundle: URL) throws {
    let edge = 256
    let context = try #require(CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(color.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
    let image = try #require(context.makeImage())
    let url = bundle.appendingPathComponent("Contents/Resources/AppIcon.icns")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "com.apple.icns" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

/// Pixel bytes for comparing which icon was produced, never against a golden image.
func pixels(_ icon: ResultIcon?) -> Data? {
    icon?.image.dataProvider?.data as Data?
}
