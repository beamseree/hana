import Foundation

/// Internal filesystem adapter. Only conventional roots are traversed; neither
/// symlinked directories nor bundle contents can turn this into a disk crawl.
@MainActor
final class ApplicationCatalog {
    static var conventionalRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
         URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }
    private struct Scan: Sendable {
        let snapshot: SourceSnapshot
        let stamps: [URL: Date]
    }
    private let roots: [URL]
    private var cached = SourceSnapshot(results: [], status: .loading)
    private var stamps: [URL: Date] = [:]
    private var subscribers: [UUID: AsyncStream<SourceSnapshot>.Continuation] = [:]
    private var monitor: Task<Void, Never>?

    init(roots: [URL]) {
        self.roots = roots
        monitor = Task { [weak self] in
            await self?.refreshIfChanged()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                await self?.refreshIfChanged()
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

    private func refreshIfChanged() async {
        let old = stamps
        let roots = roots
        // Stat the previously discovered directories and bundle metadata off the
        // input thread. Re-enumerate only on change (or the initial launch).
        let scan = await Task.detached(priority: .utility) { () -> Scan? in
            if !old.isEmpty, old.allSatisfy({ Self.stamp($0.key) == $0.value }) { return nil }
            return Self.scan(roots)
        }.value
        guard let scan else { return }
        cached = scan.snapshot
        stamps = scan.stamps
        for subscriber in subscribers.values { subscriber.yield(cached) }
    }

    private nonisolated static func stamp(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    /// The same bundle and Info.plist stamps the catalog watches, so other
    /// adapters notice an updated application without a second watcher.
    nonisolated static func changeStamp(of application: URL) -> [Date] {
        [stamp(application), stamp(application.appendingPathComponent("Contents/Info.plist"))]
    }

    private nonisolated static func scan(_ roots: [URL]) -> Scan {
        let manager = FileManager.default
        var applications: [SearchResult] = []
        var stamps: [URL: Date] = [:]
        var failed = false
        var visited = Set<URL>()
        var pending = roots
        for root in roots {
            stamps[root] = stamp(root)
            // Detect installation of a previously missing conventional root.
            stamps[root.deletingLastPathComponent()] = stamp(root.deletingLastPathComponent())
        }
        while let directory = pending.popLast() {
            let directory = directory.standardizedFileURL
            guard visited.insert(directory).inserted else { continue }
            stamps[directory] = stamp(directory)
            guard manager.fileExists(atPath: directory.path) else { continue }
            let children: [URL]
            do {
                children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey], options: [.skipsHiddenFiles])
            } catch { failed = true; continue }
            for child in children {
                guard let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]),
                      values.isHidden != true, values.isSymbolicLink != true, values.isDirectory == true else { continue }
                if child.pathExtension.lowercased() == "app" {
                    let infoURL = child.appendingPathComponent("Contents/Info.plist")
                    stamps[child] = stamp(child)
                    stamps[infoURL] = stamp(infoURL)
                    // Fresh values on refresh; Bundle caches can retain old names.
                    let info = (try? Data(contentsOf: infoURL)).flatMap {
                        try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
                    }
                    let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
                        ?? child.deletingPathExtension().lastPathComponent
                    let localized = manager.displayName(atPath: child.path)
                    applications.append(SearchResult(name: name, url: child.standardizedFileURL,
                        alternateNames: [child.deletingPathExtension().lastPathComponent,
                                         localized.hasSuffix(".app") ? String(localized.dropLast(4)) : localized]))
                } else if !["bundle", "framework", "plugin", "appex"].contains(child.pathExtension.lowercased()) {
                    pending.append(child)
                }
            }
        }
        return Scan(snapshot: SourceSnapshot(results: applications, status: failed ? .failed : .ready), stamps: stamps)
    }
}
