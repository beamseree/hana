import AppKit
import CryptoKit
import Testing
@testable import Hana

/// Two global key-window checks require NSApplication.run. The async-main test
/// helper does not dispatch AppKit activation, and manually doing so drains its
/// async main queue before a test summary. Reuse the existing exact app-loop
/// assertions in a disposable signed child; never skip or simulate key focus.
@MainActor
enum NativeAppFixture {
    enum Mode: String {
        case mainWindow = "main-window", openNoteCapture = "open-note-capture"
    }

    private final class BundleMarker: NSObject {}
    private enum Failure: Error { case missingProduct, timedOut, childExit(Int32), missingSuccessMarker }

    static func run(_ mode: Mode, requiring marker: String) async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("hana-native-app-test-\(UUID().uuidString)")
        defer { try? files.removeItem(at: root) }
        let app = root.appendingPathComponent("Hana.app")
        let contents = app.appendingPathComponent("Contents")
        let binary = contents.appendingPathComponent("MacOS/Hana")
        try files.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let product = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Hana")
        guard files.isExecutableFile(atPath: product.path) else { throw Failure.missingProduct }
        try files.copyItem(at: product, to: binary)
        try files.copyItem(at: repository.appendingPathComponent("App/Resources"), to: contents.appendingPathComponent("Resources"))
        let identifier = "com.beamseree.hana.validation.test.\(UUID().uuidString.lowercased())"
        var info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: repository.appendingPathComponent("App/Info.plist")), format: nil) as? [String: Any])
        info["CFBundleIdentifier"] = identifier
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let output = root.appendingPathComponent("process-output.txt")
        let signing = try await child(URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["--force", "--sign", "-", "--identifier", identifier, app.path], output: output)
        guard signing == 0 else { throw Failure.childExit(signing) }
        let report = root.appendingPathComponent("report.jsonl")
        let status = try await child(binary, arguments: ["--validate-\(mode.rawValue)", "--\(mode.rawValue)-report", report.path], output: output)
        let trace = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
        guard status == 0 else { throw Failure.childExit(status) }
        guard trace.contains("\"event\":\"\(marker)\""),
              trace.contains("\"event\":\"\(mode.rawValue).validation-passed\""), !trace.contains("validation-failed") else { throw Failure.missingSuccessMarker }
        let hash = SHA256.hash(data: try Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
        print("NATIVE_APP_FIXTURE mode=\(mode.rawValue) status=0 marker=\(marker) sha256=\(hash)")
    }

    private static func child(_ executable: URL, arguments: [String], output: URL) async throws -> Int32 {
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        defer {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while process.isRunning {
            guard ContinuousClock.now < deadline else {
                process.terminate()
                try await Task.sleep(for: .milliseconds(100))
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw Failure.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return process.terminationStatus
    }
}
