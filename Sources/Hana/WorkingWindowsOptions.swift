import Foundation

/// An explicit fixture launch contract. Any orphan/malformed fixture option
/// is an error rather than an invitation to open the personal collection.
struct WorkingWindowsOptions: Sendable {
    enum Mode: Sendable { case interactive, smokeWrite, smokeVerify }
    let mode: Mode
    let root: URL
    let report: URL

    static func parse(_ arguments: [String]) throws -> Self? {
        let flag = "--validate-working-windows"
        guard arguments.contains(where: { $0.hasPrefix(flag) || $0.hasPrefix("--working-windows") }) else { return nil }
        let switches = [flag, "--working-windows-interactive", "--working-windows-smoke-write", "--working-windows-smoke-verify"]
        let values = ["--working-windows-fixture-root", "--working-windows-report"]
        var seen: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard seen[key] == nil else { throw Failure.arguments }
            if switches.contains(key) {
                seen[key] = ""
            } else if values.contains(key) {
                index += 1
                guard index < arguments.count, arguments[index].hasPrefix("/") else { throw Failure.arguments }
                seen[key] = arguments[index]
            } else { throw Failure.arguments }
            index += 1
        }
        guard seen[flag] != nil, let root = seen[values[0]], let report = seen[values[1]] else { throw Failure.arguments }
        let modes: [(String, Mode)] = [(switches[1], .interactive), (switches[2], .smokeWrite), (switches[3], .smokeVerify)]
        let chosen = modes.filter { seen[$0.0] != nil }
        guard chosen.count == 1 else { throw Failure.arguments }
        return Self(mode: chosen[0].1, root: URL(fileURLWithPath: root), report: URL(fileURLWithPath: report))
    }

    enum Failure: Error { case arguments, fixture, persistence, editor }
}
