import ApplicationServices
import Foundation

extension MacInteraction {
    /// Race the OS boundary against a deadline without awaiting cancellation of
    /// foreign IPC. Only the first value is used; late replies cannot move UI.
    nonisolated static func focusedWindowWithinDeadline(
        lookup: @escaping @Sendable () async -> CGRect?
    ) async -> CGRect? {
        let (stream, continuation) = AsyncStream<CGRect?>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let worker = Task.detached(priority: .userInitiated) {
            continuation.yield(await lookup())
            continuation.finish()
        }
        let deadline = Task {
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            continuation.yield(nil)
            continuation.finish()
        }
        defer { worker.cancel(); deadline.cancel(); continuation.finish() }
        for await value in stream { return value }
        return nil
    }
}

/// Only geometry leaves this adapter. No titles, text, prompting, or global AX
/// timeout changes. Each returned element needs its own messaging timeout.
enum FocusedWindowGeometry {
    static func read(processID: pid_t) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(processID)
        guard AXUIElementSetMessagingTimeout(application, 0.015) == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        guard AXUIElementSetMessagingTimeout(window, 0.015) == .success else { return nil }
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        let position = unsafeDowncast(positionValue, to: AXValue.self)
        let size = unsafeDowncast(sizeValue, to: AXValue.self)
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
}
