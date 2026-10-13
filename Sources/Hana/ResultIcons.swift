import AppKit

/// An application icon rasterised to a bounded bitmap. Only this immutable
/// value crosses concurrency seams; lazily decoding NSImages never do.
struct ResultIcon: Sendable {
    let image: CGImage
    let scale: CGFloat
}

/// Internal presentation adapter for application result icons. It is not a
/// Search source and plays no part in eligibility, ranking or batches. The
/// in-memory cache lasts one session and is bounded by entry count.
actor ResultIcons {
    private struct Key: Hashable {
        let application: URL
        let scale: CGFloat
    }
    private struct Entry {
        let stamp: [Date]
        let icon: ResultIcon
        var lastUse: Int
    }
    private let pointSize: CGFloat
    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var uses = 0
    var cachedCount: Int { entries.count }

    init(pointSize: CGFloat = 28, capacity: Int = 128) {
        self.pointSize = pointSize
        self.capacity = max(1, capacity)
    }

    /// The icon of the exact installation, never resolved by bundle identifier,
    /// or nil when none can be produced and the caller should fall back.
    func icon(for application: URL, scale: CGFloat) -> ResultIcon? {
        let key = Key(application: application.standardizedFileURL, scale: scale)
        let stamp = ApplicationCatalog.changeStamp(of: key.application)
        uses += 1
        if let entry = entries[key], entry.stamp == stamp {
            entries[key]?.lastUse = uses
            return entry.icon
        }
        guard let icon = Self.rasterise(key.application, pixels: Int((pointSize * scale).rounded()), scale: scale) else {
            entries[key] = nil
            return nil
        }
        entries[key] = Entry(stamp: stamp, icon: icon, lastUse: uses)
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries[oldest] = nil
        }
        return icon
    }

    private static func rasterise(_ application: URL, pixels: Int, scale: CGFloat) -> ResultIcon? {
        // The workspace answers even for a missing or locked path, with a
        // generic image. Those fall back to the row's own symbol instead.
        guard access(application.path, R_OK | X_OK) == 0 else { return nil }
        let source = NSWorkspace.shared.icon(forFile: application.path)
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // NSGraphicsContext.current is per-thread, so drawing here stays off the main actor.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map { ResultIcon(image: $0, scale: scale) }
    }
}
