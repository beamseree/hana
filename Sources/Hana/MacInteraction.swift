import AppKit

/// Owns the native Search lifetime. Callers carry Invocation into any delayed
/// completion so an obsolete operation cannot dismiss a newer session.
@MainActor
final class MacInteraction: NSObject, NSTextViewDelegate {
    struct Invocation: Equatable {
        fileprivate let id = UUID()
    }

    enum DismissalReason: String {
        case escape, outsideClick, appSwitch, environmentChange
    }

    private(set) var currentInvocation: Invocation?
    private let panel = SearchPanel(
        contentRect: NSRect(x: 0, y: 0, width: 660, height: 64),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    private let editor = SearchEditor(frame: .zero)
    private let diagnostics: Diagnostics
    private var origin: NSRunningApplication?
    private var localMouse: Any?
    private var globalMouse: Any?
    private var menuDepth = 0
    private var statusItem: NSStatusItem?
    private var shortcutStatus: NSMenuItem?
    private var hotKey: GlobalShortcut?

    init(diagnostics: Diagnostics = Diagnostics()) {
        self.diagnostics = diagnostics
        super.init()
        configurePanel()
    }

    /// Called once by the app delegate, never as a side effect of a test's init.
    func start() {
        NSApp.setActivationPolicy(.accessory)
        configureMenus()
        let shortcut = GlobalShortcut { [weak self] in
            self?.record("hotkey.received")
            self?.presentBar()
        }
        hotKey = shortcut
        let result = shortcut.register()
        shortcutStatus?.title = result == noErr
            ? "Option+Space is available"
            : "Option+Space unavailable (\(result)) — use Search"
        statusItem?.button?.title = result == noErr ? "Hana" : "Hana !"
        record("startup", extra: ["shortcutStatus": result, "screenCount": NSScreen.screens.count])
    }

    func stop() {
        if let invocation = currentInvocation { dismiss(invocation, reason: .environmentChange) }
        hotKey?.unregister()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        record("shutdown")
    }

    @discardableResult
    func presentBar() -> Invocation {
        let started = ProcessInfo.processInfo.systemUptime
        let existing = currentInvocation != nil
        let invocation = currentInvocation ?? Invocation()
        if !existing {
            origin = NSWorkspace.shared.frontmostApplication
            currentInvocation = invocation
            clearEditor()
            placeOnPointerDisplay()
            observeSession(invocation)
        }
        // Do not activate the process: the nonactivating panel takes key focus
        // while the foreign invocation origin keeps its ordinary activation.
        panel.makeKeyAndOrderFront(nil)
        let accepted = panel.makeFirstResponder(editor)
        record(existing ? "invoke.existing" : "invoke.new", extra: [
            "responderAccepted": accepted,
            "presentationMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000
        ])
        return invocation
    }

    func dismiss(_ invocation: Invocation, reason: DismissalReason) {
        guard currentInvocation == invocation else {
            record("dismiss.stale-ignored")
            return
        }
        record("dismiss.\(reason.rawValue)")
        currentInvocation = nil
        removeSessionObservers()
        panel.orderOut(nil)
        clearEditor()
        // The foreign origin normally never lost activation. Ordering out the
        // nonactivating panel releases its key focus. Never activate an old app
        // over a subsequent user choice, even for Escape. Restoration is best effort.
        origin = nil
    }

    private func configurePanel() {
        panel.title = "Hana Search"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        // Only the pixels outside the rounded surface are transparent.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let surface = NSView(frame: panel.contentView!.bounds)
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.white.cgColor
        surface.layer?.cornerRadius = 16
        surface.layer?.masksToBounds = true
        panel.contentView = surface

        let scroll = NSScrollView(frame: NSRect(x: 18, y: 12, width: 624, height: 40))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        editor.frame = scroll.bounds
        editor.minSize = NSSize(width: 0, height: 40)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 0, height: 7)
        editor.font = .systemFont(ofSize: 22)
        editor.textColor = .black
        editor.insertionPointColor = .black
        editor.backgroundColor = .white
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setAccessibilityLabel("Search")
        editor.delegate = self
        editor.escape = { [weak self] in
            guard let self, let invocation = self.currentInvocation else { return }
            self.dismiss(invocation, reason: .escape)
        }
        scroll.documentView = editor
        surface.addSubview(scroll)
    }

    private func clearEditor() {
        editor.unmarkText()
        editor.string = ""
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.undoManager?.removeAllActions()
    }

    private func placeOnPointerDisplay() {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? NSScreen.screens.first else { return }
        let bounds = screen.visibleFrame
        let width = min(660, bounds.width)
        let height = min(64, bounds.height)
        let y = max(bounds.minY, min(bounds.maxY - height, bounds.maxY - 100 - height))
        panel.setFrame(NSRect(x: bounds.midX - width / 2, y: y, width: width, height: height), display: false)
        record("placement.pointer", extra: ["visibleFrame": NSStringFromRect(bounds)])
    }

    private func observeSession(_ invocation: Invocation) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, self.menuDepth == 0 {
                    self.dismiss(invocation, reason: .outsideClick)
                }
            }
            return event
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.menuDepth == 0, !self.editor.hasMarkedText() else { return }
                self.dismiss(invocation, reason: .outsideClick)
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(environmentChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(environmentChanged), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(environmentChanged), name: NSWorkspace.screensDidSleepNotification, object: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(environmentChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(menuBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEnded), name: NSMenu.didEndTrackingNotification, object: nil)
    }

    private func removeSessionObservers() {
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        localMouse = nil
        globalMouse = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        // NSTextView also registers its delegate for notifications. Remove only
        // this session's subscriptions, preserving native text-change delivery.
        for name in [NSApplication.didChangeScreenParametersNotification,
                     NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            NotificationCenter.default.removeObserver(self, name: name, object: nil)
        }
        menuDepth = 0
    }

    @objc private func environmentChanged() {
        if let invocation = currentInvocation { dismiss(invocation, reason: .environmentChange) }
    }

    @objc private func appChanged(_ notification: Notification) {
        guard let invocation = currentInvocation,
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != origin?.processIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              menuDepth == 0, !editor.hasMarkedText() else { return }
        dismiss(invocation, reason: .appSwitch)
    }

    @objc private func menuBegan() { menuDepth += 1 }
    @objc private func menuEnded() { menuDepth = max(0, menuDepth - 1) }
    @objc private func invokeFromMenu() { presentBar() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func configureMenus() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = status
        let menu = NSMenu()
        let search = NSMenuItem(title: "Search", action: #selector(invokeFromMenu), keyEquivalent: "")
        search.target = self
        menu.addItem(search)
        let availability = NSMenuItem(title: "Registering Option+Space…", action: nil, keyEquivalent: "")
        availability.isEnabled = false
        shortcutStatus = availability
        menu.addItem(availability)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Hana", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        status.menu = menu

        let main = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu(title: "Hana")
        application.submenu?.addItem(quit.copy() as! NSMenuItem)
        main.addItem(application)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
            ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
            ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
        ] {
            edit.submenu?.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        main.addItem(edit)
        NSApp.mainMenu = main
    }

    func textDidChange(_ notification: Notification) { record("editor.changed") }

    private func record(_ event: String, extra: [String: Any] = [:]) {
        guard diagnostics.isEnabled else { return }
        var state: [String: Any] = [
            "session": currentInvocation?.id.uuidString ?? "none",
            "policy": NSApp.activationPolicy() == .accessory ? "accessory" : "other",
            "barVisible": panel.isVisible, "barKey": panel.isKeyWindow,
            "editorResponder": panel.firstResponder === editor,
            "barOnActiveSpace": panel.isOnActiveSpace, "barLevel": panel.level.rawValue,
            "barFrame": NSStringFromRect(panel.frame), "textUTF16Count": editor.string.utf16.count,
            "marked": editor.hasMarkedText(),
            "originBundle": origin?.bundleIdentifier ?? "none",
            "frontBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        ]
        state.merge(extra) { _, new in new }
        diagnostics.record(event, state: state)
    }
}

@MainActor
private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SearchEditor: NSTextView {
    var escape: (() -> Void)?
    override var needsPanelToBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !hasMarkedText() {
            escape?()
            return
        }
        super.keyDown(with: event)
    }
}
