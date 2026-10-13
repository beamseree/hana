import Foundation

/// Where a collection lives. The live root is the personal build's private
/// Application Support directory; fixture roots are explicitly marked
/// disposable and may never be the live root, a descendant or an alias of it.
struct CollectionLocation: Sendable, Equatable {
    static let bundleIdentifier = "com.beamseree.hana"
    static let fixtureMarkerName = "HANA-DISPOSABLE-FIXTURE"

    let root: URL
    let isFixture: Bool

    var collectionDirectory: URL { root.appendingPathComponent("Collection", isDirectory: true) }
    var databaseURL: URL { collectionDirectory.appendingPathComponent("collection.sqlite") }
    /// Written once a collection has been published; afterwards a missing
    /// `Collection` directory is an error, never a new store.
    var initializedMarkerURL: URL { root.appendingPathComponent("collection-initialized") }

    /// `~/Library/Application Support/com.beamseree.hana/`, resolved through the
    /// user's Application Support directory. Nothing here creates it.
    static var defaultLiveRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static func live() -> CollectionLocation {
        CollectionLocation(root: defaultLiveRoot, isFixture: false)
    }

    /// Creates a genuinely new owner-only fixture root and marks it disposable.
    static func createFixtureRoot(at root: URL, liveRoot: URL = defaultLiveRoot) throws -> CollectionLocation {
        try refuseLive(root, liveRoot: liveRoot)
        guard mkdir(root.path, 0o700) == 0 else { throw CollectionStoreError.fixtureRootUnavailable }
        let marker = root.appendingPathComponent(fixtureMarkerName)
        guard FileManager.default.createFile(atPath: marker.path, contents: Data("Disposable Hana collection fixture.\n".utf8),
                                             attributes: [.posixPermissions: 0o600])
        else { throw CollectionStoreError.fixtureRootUnavailable }
        return CollectionLocation(root: root, isFixture: true)
    }

    /// An existing fixture root; it must carry the disposable marker.
    static func fixture(_ root: URL, liveRoot: URL = defaultLiveRoot) throws -> CollectionLocation {
        try refuseLive(root, liveRoot: liveRoot)
        var info = stat()
        guard lstat(root.appendingPathComponent(fixtureMarkerName).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG
        else { throw CollectionStoreError.notDisposableFixture }
        return CollectionLocation(root: root, isFixture: true)
    }

    private init(root: URL, isFixture: Bool) {
        self.root = root
        self.isFixture = isFixture
    }

    /// Refuses the live root, its descendants, and any other name for them:
    /// symlinks, case variants or another path to the same directory. Runs
    /// before anything is created.
    private static func refuseLive(_ candidate: URL, liveRoot: URL) throws {
        let (candidateAnchor, candidateRest) = anchored(candidate)
        let (liveAnchor, liveRest) = anchored(liveRoot)
        if candidateAnchor == liveAnchor, candidateRest.starts(with: liveRest) { throw CollectionStoreError.liveRootRefused }
        guard let live = identity(liveRoot.path) else { return }
        var ancestor = candidate.standardizedFileURL
        while ancestor.path != "/" {
            if identity(ancestor.path) == live { throw CollectionStoreError.liveRootRefused }
            ancestor.deleteLastPathComponent()
        }
    }

    /// The deepest existing ancestor's file identity and the remaining
    /// lowercased components below it.
    private static func anchored(_ url: URL) -> (anchor: FileIdentity?, rest: [String]) {
        var ancestor = url.standardizedFileURL
        var rest: [String] = []
        while ancestor.path != "/" {
            if let identity = identity(ancestor.path) { return (identity, rest) }
            rest.insert(ancestor.lastPathComponent.lowercased(), at: 0)
            ancestor.deleteLastPathComponent()
        }
        return (identity("/"), rest)
    }

    private struct FileIdentity: Equatable { let device: dev_t; let inode: ino_t }

    private static func identity(_ path: String) -> FileIdentity? {
        var info = stat()
        return stat(path, &info) == 0 ? FileIdentity(device: info.st_dev, inode: info.st_ino) : nil
    }
}
