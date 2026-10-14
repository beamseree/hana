import Testing

/// The coordinated native testing slot. Suites that present real windows share
/// the process-wide key window, first responder and main actor, and
/// `.serialized` only orders tests within one suite. Each suite with this trait
/// holds the slot for its whole run, so no two such suites overlap.
struct NativeWindowSlot: SuiteTrait, TestScoping {
    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        await Self.lock.acquire()
        do { try await function() } catch {
            await Self.lock.release()
            throw error
        }
        await Self.lock.release()
    }

    private static let lock = Lock()

    private actor Lock {
        private var held = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func acquire() async {
            guard held else { held = true; return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
        }
    }
}

extension Trait where Self == NativeWindowSlot {
    static var nativeWindowSlot: Self { Self() }
}
