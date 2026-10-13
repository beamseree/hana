import AppKit

// Disposable destination probe. Its two installations deliberately share one
// bundle ID and name; the visible window identifies the exact running URL.
@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let installation = Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 580, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Hana Search Fixture — \(installation)"
        let label = NSTextField(labelWithString: "Installation: \(installation) · temporary focus probe; nothing is saved")
        label.frame = NSRect(x: 20, y: 140, width: 540, height: 40)
        let input = NSTextField(frame: NSRect(x: 20, y: 70, width: 540, height: 28))
        input.placeholderString = "Type here without clicking after launch"
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(input)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
        self.window = window
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let application = NSApplication.shared
let delegate = FixtureDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
