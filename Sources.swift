// THROWAWAY native window experiment. No collection, search, persistence or production scaffold.
import AppKit
import Carbon
import ApplicationServices

@MainActor final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class ProbeEditor: NSTextView {
    var record: ((String) -> Void)?
    var escape: (() -> Void)?
    override var needsPanelToBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        let composing = hasMarkedText()
        record?("keyDown escape=\(event.keyCode == 53) composing=\(composing)")
        // Let the text input system see composition Escape first. Never globally intercept keys.
        if event.keyCode == 53 && !composing, let escape {
            escape()
            return
        }
        super.keyDown(with: event)
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
        record?("insertText")
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        record?("setMarkedText")
    }
    override func unmarkText() {
        super.unmarkText()
        record?("unmarkText")
    }
}

@MainActor final class WindowExperiment: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextViewDelegate {
    private var panel: BarPanel!
    private var editor: ProbeEditor!
    private var status: NSStatusItem!
    private var label: NSTextField!
    private var working: [String: NSWindow] = [:]
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var localMouse: Any?
    private var globalMouse: Any?
    private var session = 0
    private var origin: NSRunningApplication?
    private weak var originWindow: NSWindow?
    private weak var originResponder: NSResponder?
    private var placement = "none"
    private var expanded = false
    private var menuDepth = 0
    private var log: FileHandle!
    private let logURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("window-focus-prototype.jsonl")

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try! FileHandle(forWritingTo: logURL)
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.accessory)
        makeMenus()
        makePanel()
        installHotKey()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.screensDidSleepNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        record("launch", extra: ["os": ProcessInfo.processInfo.operatingSystemVersionString, "log": logURL.path,
                                 "screens": NSScreen.screens.map { ["frame": NSStringFromRect($0.frame), "visible": NSStringFromRect($0.visibleFrame)] },
                                 "axTrusted": AXIsProcessTrusted()])
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }
    private func controlsMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("Show bar (Option+Space)", #selector(showBar)))
        m.addItem(item("Open main window", #selector(openMain), key: "1"))
        m.addItem(item("Open mock note A", #selector(openA), key: "2"))
        m.addItem(item("Open mock note B", #selector(openB), key: "3"))
        m.addItem(.separator())
        m.addItem(item("Minimize all working windows", #selector(minimizeAll)))
        m.addItem(item("Close all working windows", #selector(closeAll)))
        m.addItem(item("Record checkpoint", #selector(checkpoint)))
        m.addItem(.separator())
        m.addItem(item("Quit prototype", #selector(quit), key: "q"))
        return m
    }
    private func makeMenus() {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "WF"
        status.button?.toolTip = "Window Focus Prototype — mock content only"
        status.menu = controlsMenu()
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = controlsMenu()
        main.addItem(appItem)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        for (name, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu?.addItem(NSMenuItem(title: name, action: Selector(action), keyEquivalent: key))
        }
        main.addItem(edit)
        NSApp.mainMenu = main
    }
    private func makeEditor(frame: NSRect, name: String) -> ProbeEditor {
        let e = ProbeEditor(frame: frame)
        e.isRichText = false
        e.allowsUndo = true
        e.font = .systemFont(ofSize: 19)
        e.textColor = .black
        e.backgroundColor = .white
        e.textContainerInset = NSSize(width: 10, height: 9)
        e.isVerticallyResizable = true
        e.isHorizontallyResizable = false
        e.autoresizingMask = [.width]
        e.textContainer?.widthTracksTextView = true
        e.setAccessibilityLabel(name)
        e.record = { [weak self] event in self?.record("\(name).\(event)") }
        return e
    }
    private func makePanel() {
        panel = BarPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 166), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Prototype bar"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .white
        panel.isOpaque = true
        panel.hasShadow = true
        panel.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 166))
        panel.contentView = content
        let scroll = NSScrollView(frame: NSRect(x: 14, y: 62, width: 632, height: 90))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        editor = makeEditor(frame: scroll.bounds, name: "Bar editor")
        editor.delegate = self
        editor.escape = { [weak self] in self?.dismiss("escape", restore: true) }
        scroll.documentView = editor
        content.addSubview(scroll)
        for (index, pair) in [("Main", #selector(openMain)), ("Note A", #selector(openA)), ("Note B", #selector(openB)), ("Expand / shrink", #selector(morph))].enumerated() {
            let button = NSButton(title: pair.0, target: self, action: pair.1)
            button.frame = NSRect(x: 14 + index * 125, y: 30, width: 120, height: 28)
            button.bezelStyle = .rounded
            content.addSubview(button)
        }
        label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 18, y: 7, width: 624, height: 18)
        label.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        label.textColor = .darkGray
        content.addSubview(label)
    }
    private func installHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let install = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            MainActor.assumeIsolated {
                guard let context else { return OSStatus(eventNotHandledErr) }
                let experiment = Unmanaged<WindowExperiment>.fromOpaque(context).takeUnretainedValue()
                experiment.record("hotkey.received")
                experiment.showBar()
                return noErr
            }
        }, 1, &eventType, context, &handler)
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x57465052, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        record("hotkey.registration", extra: ["handlerStatus": install, "registrationStatus": registered])
        if registered != noErr { status.button?.title = "WF !" }
    }

    @objc func showBar() {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(editor)
            record("invoke.existing")
            return
        }
        session += 1
        origin = NSWorkspace.shared.frontmostApplication
        originWindow = NSApp.keyWindow
        originResponder = originWindow?.firstResponder
        editor.string = ""
        editor.undoManager?.removeAllActions()
        expanded = false
        let screen = workingScreen()
        let bounds = screen.visibleFrame
        panel.setFrame(NSRect(x: bounds.midX - min(660, bounds.width) / 2, y: bounds.maxY - 100 - 166, width: min(660, bounds.width), height: 166), display: false)
        installMouseMonitors()
        panel.makeKeyAndOrderFront(nil)
        let responder = panel.makeFirstResponder(editor)
        record("invoke.new", extra: ["responderAccepted": responder])
    }
    private func workingScreen() -> NSScreen {
        if origin?.processIdentifier == ProcessInfo.processInfo.processIdentifier, let screen = originWindow?.screen {
            placement = "owned-window"
            return screen
        }
        if AXIsProcessTrusted(), let origin {
            let application = AXUIElementCreateApplication(origin.processIdentifier)
            AXUIElementSetMessagingTimeout(application, 0.08)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success, let value {
                let window = value as! AXUIElement
                var position: CFTypeRef?
                var size: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                   AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
                   let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                    var p = CGPoint.zero
                    var s = CGSize.zero
                    AXValueGetValue(position as! AXValue, .cgPoint, &p)
                    AXValueGetValue(size as! AXValue, .cgSize, &s)
                    let rect = NSRect(x: p.x, y: NSScreen.screens[0].frame.maxY - p.y - s.height, width: s.width, height: s.height)
                    let best = NSScreen.screens.max { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }
                    if let best, area(best.frame.intersection(rect)) > 0 { placement = "AX-focused-window"; return best }
                }
            }
        }
        placement = "pointer-fallback"
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.screens[0]
    }
    private func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
    private func installMouseMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, self.menuDepth == 0 {
                    self.dismiss("outside.local", restore: false)
                }
            }
            return event
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Candidate UI is not a cancellation. This conservative guard requires real IME validation.
                if self.editor.hasMarkedText() || self.menuDepth > 0 { self.record("outside.deferred-composition-or-menu"); return }
                self.dismiss("outside.global", restore: false)
            }
        }
    }
    private func dismiss(_ reason: String, restore: Bool) {
        guard panel.isVisible else { return }
        record("dismiss.\(reason).before")
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let shouldRestoreOwned = restore && origin?.processIdentifier == ProcessInfo.processInfo.processIdentifier && front == origin?.processIdentifier
        panel.orderOut(nil)
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        localMouse = nil; globalMouse = nil
        editor.string = ""
        editor.undoManager?.removeAllActions()
        // Foreign origin normally never lost activation. Do not activate it over a later user choice.
        if shouldRestoreOwned, let originWindow, originWindow.isVisible, !originWindow.isMiniaturized {
            originWindow.makeKey()
            if let originResponder { originWindow.makeFirstResponder(originResponder) }
        }
        record("dismiss.\(reason).after")
    }
    private func openWorking(_ id: String) {
        let mock = panel.isVisible ? editor.string : "Mock \(id). Nothing is saved."
        dismiss("destination", restore: false)
        if working[id] == nil {
            let w = NSWindow(contentRect: NSRect(x: 220 + working.count * 70, y: 200 + working.count * 55, width: 620, height: 400), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "WF — \(id) — mock only"
            w.isReleasedWhenClosed = false
            w.delegate = self
            let scroll = NSScrollView(frame: w.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let text = makeEditor(frame: scroll.bounds, name: id)
            text.string = mock
            scroll.documentView = text
            w.contentView?.addSubview(scroll)
            w.initialFirstResponder = text
            working[id] = w
        }
        updatePolicy()
        let w = working[id]!
        if w.isMiniaturized { w.deminiaturize(nil) }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        record("working.open.\(id)")
    }
    private func updatePolicy() {
        let desired: NSApplication.ActivationPolicy = working.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != desired {
            let accepted = NSApp.setActivationPolicy(desired)
            record("policy.changed", extra: ["accepted": accepted])
        }
    }
    @objc private func openMain() { openWorking("Main") }
    @objc private func openA() { openWorking("Note A") }
    @objc private func openB() { openWorking("Note B") }
    @objc private func minimizeAll() { for w in working.values { w.miniaturize(nil) }; record("working.minimize-all") }
    @objc private func closeAll() { for w in Array(working.values) { w.close() }; record("working.close-all") }
    @objc private func checkpoint() { record("checkpoint") }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func morph() {
        expanded.toggle()
        var frame = panel.frame
        let top = frame.maxY
        frame.size.height = expanded ? 340 : 166
        frame.origin.y = top - frame.height
        panel.setFrame(frame, display: true, animate: false)
        panel.makeFirstResponder(editor)
        record("morph")
    }
    @objc private func spaceChanged() { record("space.changed"); dismiss("space-change", restore: false) }
    @objc private func sleeping() { dismiss("sleep", restore: false) }
    @objc private func screensChanged() {
        dismiss("screens-change", restore: false)
        for w in working.values where !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) { w.center() }
        record("screens.changed")
    }
    @objc private func appChanged(_ notification: Notification) {
        record("workspace.activated")
        guard panel.isVisible, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier != origin?.processIdentifier && app.processIdentifier != ProcessInfo.processInfo.processIdentifier && !editor.hasMarkedText() && menuDepth == 0 {
            dismiss("app-switch", restore: false)
        }
    }
    @objc private func menuBegan() { menuDepth += 1; record("menu.begin") }
    @objc private func menuEnded() { menuDepth = max(0, menuDepth - 1); record("menu.end") }
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w !== panel else { return }
        working = working.filter { $0.value !== w }
        updatePolicy()
        record("working.closed")
    }
    func windowDidBecomeKey(_ notification: Notification) { record("window.becameKey") }
    func windowDidResignKey(_ notification: Notification) { record("window.resignedKey") }
    func windowDidMiniaturize(_ notification: Notification) { record("window.minimized") }
    func windowDidDeminiaturize(_ notification: Notification) { record("window.deminiaturized") }
    func textDidChange(_ notification: Notification) { record("editor.changed") }
    func textViewDidChangeSelection(_ notification: Notification) { record("editor.selection") }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openMain(); return false }
    func applicationWillTerminate(_ notification: Notification) {
        record("terminate")
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        try? log.close()
    }
    private func record(_ event: String, extra: [String: Any] = [:]) {
        guard log != nil else { return }
        let policy = NSApp.activationPolicy() == .regular ? "regular" : "accessory"
        var row: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()), "uptime": ProcessInfo.processInfo.systemUptime,
            "event": event, "session": session, "policy": policy, "appActive": NSApp.isActive,
            "frontBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none",
            "originBundle": origin?.bundleIdentifier ?? "none", "keyWindow": NSApp.keyWindow?.title ?? "none",
            "barVisible": panel?.isVisible ?? false, "barKey": panel?.isKeyWindow ?? false,
            "barOnActiveSpace": panel?.isOnActiveSpace ?? false, "barLevel": panel?.level.rawValue ?? -1,
            "editorResponder": panel?.firstResponder === editor, "editorUTF16": editor?.string.utf16.count ?? 0,
            "marked": editor?.hasMarkedText() ?? false, "selection": NSStringFromRange(editor?.selectedRange() ?? NSRange(location: 0, length: 0)),
            "placement": placement, "barFrame": panel.map { NSStringFromRect($0.frame) } ?? "none",
            "working": working.keys.sorted().map { id -> [String: Any] in let w = working[id]!; return ["id": id, "minimized": w.isMiniaturized, "visible": w.isVisible, "key": w.isKeyWindow, "onActiveSpace": w.isOnActiveSpace] }
        ]
        row.merge(extra) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            try? log.write(contentsOf: data + Data([10]))
        }
        label?.stringValue = "THROWAWAY · \(policy) · windows \(working.count) · session \(session) · \(event)"
    }
}

let app = NSApplication.shared
let experiment = WindowExperiment()
app.delegate = experiment
app.run()
