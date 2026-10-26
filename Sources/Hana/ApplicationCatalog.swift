import CoreServices
import Foundation

/// Internal filesystem adapter. Only conventional roots are traversed; neither
/// symlinked directories nor bundle contents can turn this into a disk crawl.
/// The enumeration is cached at launch and repeated only when the filesystem
/// reports a change beneath a root; while nothing changes it does no work.
@MainActor
final class ApplicationCatalog {
    nonisolated static var conventionalRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
         URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }
    private let roots: [URL]
    private var cached = SourceSnapshot(results: [], status: .loading)
    private var subscribers: [UUID: AsyncStream<SourceSnapshot>.Continuation] = [:]
    private var monitor: Task<Void, Never>?
    /// Filesystem passes so far, the launch enumeration included.
    private(set) var scans = 0
    /// The least time between rescans, so a long installation rescans at a
    /// bounded rate rather than once per reported batch.
    private nonisolated static let rescanInterval: Duration = .seconds(2)

    init(roots: [URL]) {
        self.roots = roots
        // Watch before the launch enumeration, so no change falls between them.
        let changes = Changes.signals(under: roots)
        monitor = Task { [weak self] in
            await self?.rescan()
            // The signal stream buffers one element, so changes reported
            // during a rescan or the interval after it coalesce into a single
            // further rescan. Cancellation ends the stream at the next
            // iteration, which stops watching.
            for await _ in changes {
                await self?.rescan()
                try? await Task.sleep(for: Self.rescanInterval)
            }
        }
    }
    deinit { monitor?.cancel() }

    func snapshots() -> AsyncStream<SourceSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SourceSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(cached)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    private func rescan() async {
        let roots = roots, previous = cached
        // Enumerate and compare off the input thread. A rescan that finds
        // nothing new, such as one for a change reported late, publishes nothing.
        let snapshot = await Task.detached(priority: .utility) { () -> SourceSnapshot? in
            let snapshot = Self.scan(roots)
            return snapshot.status == previous.status && snapshot.results == previous.results ? nil : snapshot
        }.value
        scans += 1
        guard let snapshot else { return }
        cached = snapshot
        for subscriber in subscribers.values { subscriber.yield(cached) }
    }

    private nonisolated static func stamp(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// Bundle and Info.plist stamps, so other adapters notice an updated
    /// application without watching the filesystem themselves.
    nonisolated static func changeStamp(of application: URL) -> [Date] {
        [stamp(application), stamp(application.appendingPathComponent(infoPlist))]
    }

    private nonisolated static func scan(_ roots: [URL]) -> SourceSnapshot {
        let manager = FileManager.default
        var applications: [SearchResult] = []
        var failed = false
        var visited = Set<URL>()
        var pending = roots
        while let directory = pending.popLast() {
            let directory = directory.standardizedFileURL
            guard visited.insert(directory).inserted else { continue }
            guard manager.fileExists(atPath: directory.path) else { continue }
            let children: [URL]
            do {
                children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey], options: [.skipsHiddenFiles])
            } catch { failed = true; continue }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]),
                      values.isHidden != true, values.isSymbolicLink != true, values.isDirectory == true else { continue }
                if child.pathExtension.lowercased() == "app" {
                    let infoURL = child.appendingPathComponent(infoPlist)
                    // Fresh values on refresh; Bundle caches can retain old names.
                    let info = (try? Data(contentsOf: infoURL)).flatMap {
                        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
                    }
                    let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
                        ?? child.deletingPathExtension().lastPathComponent
                    let localized = manager.displayName(atPath: child.path)
                    applications.append(SearchResult(name: name, url: child.standardizedFileURL,
                        alternateNames: [info?["CFBundleName"] as? String ?? name,
                                         child.deletingPathExtension().lastPathComponent,
                                         localized.hasSuffix(".app") ? String(localized.dropLast(4)) : localized]))
                } else if !bundleExtensions.contains(child.pathExtension.lowercased()) {
                    pending.append(child)
                }
            }
        }
        return SourceSnapshot(results: applications, status: failed ? .failed : .ready)
    }

    private nonisolated static let infoPlist = "Contents/Info.plist"
    /// Applications are listed and other bundles skipped; neither is descended.
    private nonisolated static let bundleExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "appex"]
    /// Lost history, a moved root or a mount: anything beneath may differ.
    private nonisolated static let alwaysRescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
        | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount)
    private nonisolated static let directory = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir)
    private nonisolated static let itemKinds = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsFile
        | kFSEventStreamEventFlagItemIsSymlink | kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink)

    /// Whether a reported change can alter the enumeration. Lost history or a
    /// moved root always can. Otherwise the enumeration reads only directories
    /// outside bundles, and each application's Info.plist inside its Contents.
    private nonisolated static func affectsEnumeration(_ path: String, flags: FSEventStreamEventFlags) -> Bool {
        if flags & alwaysRescan != 0 { return true }
        func pathExtension(_ component: Substring) -> String { (String(component) as NSString).pathExtension.lowercased() }
        let components = path.split(separator: "/")
        if let bundle = components.firstIndex(where: { bundleExtensions.contains(pathExtension($0)) }), bundle < components.count - 1 {
            let inner = components[(bundle + 1)...].joined(separator: "/").lowercased()
            return pathExtension(components[bundle]) == "app" && (inner == "contents" || inner == infoPlist.lowercased())
        }
        // An event without an item kind is conservatively treated as a directory's.
        return flags & directory != 0 || flags & itemKinds == 0
    }
}

extension ApplicationCatalog {
    /// Reports filesystem changes beneath the roots that can alter the
    /// enumeration as a signal, at most once per `latency`, so a burst of
    /// changes coalesces into one report.
    private final class Changes: @unchecked Sendable {
        private static let latency: CFTimeInterval = 0.5
        private let roots: [String]
        private let queue = DispatchQueue(label: "Hana.ApplicationCatalog.changes", qos: .utility)
        private let changed: AsyncStream<Void>.Continuation
        // Confined to `queue`.
        private var stream: FSEventStreamRef?

        private init(roots: [String], changed: AsyncStream<Void>.Continuation) {
            self.roots = roots
            self.changed = changed
        }

        /// Watching starts before this returns and stops when iteration ends.
        static func signals(under roots: [URL]) -> AsyncStream<Void> {
            let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let changes = Changes(roots: roots.map(\.path), changed: continuation)
            changes.queue.sync { changes.start() }
            continuation.onTermination = { _ in changes.queue.async { changes.stop() } }
            return signals
        }

        private func start() {
            guard !roots.isEmpty else { return }
            // Unretained: the stream is released in `stop()`, before this object.
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                guard let info, (0..<count).contains(where: { affectsEnumeration(String(cString: paths[$0]), flags: flags[$0]) })
                else { return }
                Unmanaged<Changes>.fromOpaque(info).takeUnretainedValue().changed.yield()
            }
            guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                                   FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
                                                   FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
            else { return }
            FSEventStreamSetDispatchQueue(stream, queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                return
            }
            self.stream = stream
        }

        private func stop() {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
