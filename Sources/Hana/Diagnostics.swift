import Foundation

/// Opt-in, content-free JSONL. No query text, key values, window titles or filenames.
@MainActor
final class Diagnostics {
    private var file: FileHandle?
    var isEnabled: Bool { file != nil }

    init(enabled: Bool = false) {
        guard enabled else { return }
        open(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Hana/native-shell.jsonl"))
    }

    /// Records to `url` instead of the user's log, for tests.
    init(file url: URL) {
        open(url)
    }

    private func open(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            file = try FileHandle(forWritingTo: url)
            try file?.seekToEnd()
            record("diagnostics.enabled", state: ["bundle": Bundle.main.bundleIdentifier ?? "unbundled"])
        } catch {
            // Do not print error descriptions: they can contain personal paths.
            fputs("Hana: diagnostic log unavailable.\n", stderr)
        }
    }

    func record(_ event: String, state: [String: Any]) {
        guard let file else { return }
        var row = state
        row["event"] = event
        row["time"] = ISO8601DateFormatter().string(from: Date())
        row["uptime"] = ProcessInfo.processInfo.systemUptime
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            try? file.write(contentsOf: data + Data([10]))
        }
    }
}
