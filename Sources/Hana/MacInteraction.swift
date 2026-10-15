import AppKit
import ApplicationServices
import SwiftUI

/// Owns the native Search lifetime. Callers carry Invocation into any delayed
/// completion so an obsolete operation cannot dismiss a newer session.
@MainActor
final class MacInteraction: NSObject, NSTextViewDelegate, NSWindowDelegate {
    struct Invocation: Equatable {
        fileprivate let id = UUID()
    }

    /// The native open acknowledgment contains the exact running instance's
    /// activation effect. Issuing that effect is fenced by invocation/query.
    struct OpenedApplication {
        let activate: @MainActor () -> Bool
    }

    enum DismissalReason: String {
        case escape, outsideClick, appSwitch, environmentChange, destination
        /// A capture was saved and its confirmation ended.
        case saved
    }

    private(set) var currentInvocation: Invocation?
    private let panel = SearchPanel(
        contentRect: NSRect(x: 0, y: 0, width: BarStyle.width, height: BarStyle.collapsedHeight),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    private let editor = SearchEditor(frame: .zero)
    private let editorScroll = NSScrollView()
    /// Capture rules live in the session; this class only performs its effects.
    private var capture = CaptureSession()
    /// Shows the current mode: the Hana logo for empty Search, a magnifying glass once it has a query.
    private let modeIcon = ModeIconView(frame: BarStyle.modeIconFrame)
    /// Stands in for a consumed mode prefix; the prefix never becomes text.
    private let modeLabel = NSTextField(labelWithString: "Note")
    /// Explains why a capture wasn't saved, below the writing surface.
    private let captureNotice = NSTextField(wrappingLabelWithString: "")
    /// The live collection, opened in the background at launch. Nil, or a
    /// failed opening, leaves Search working and capture unavailable.
    private let collection: Task<CollectionStore, any Error>?
    private let confirmationDuration: Duration
    /// The workspace's frontmost application; replaceable because a test
    /// runner can't be activated.
    private let frontmostApplication: @MainActor () -> NSRunningApplication?
    private var confirmationTask: Task<Void, Never>?
    private let loadingIndicator = NSProgressIndicator()
    private let search: Search
    private let launchApplication: @MainActor (URL) async throws -> OpenedApplication
    private let openFile: @MainActor (URL) async throws -> OpenedApplication
    private let loadIcon: @MainActor (URL, CGFloat) async -> ResultIcon?
    private var iconRequests: Set<SearchResult.ID> = []
    /// Icons for current results only; Result Icons owns the bounded cache.
    private(set) var icons: [SearchResult.ID: ResultIcon] = [:]
    private var fileStatus: SourceStatus = .ready
    private var searchTask: Task<Void, Never>?
    private var request: Search.Request?
    private var selectedID: SearchResult.ID?
    private var userMovedSelection = false
    private var resultSurface: NSHostingView<SearchResultsView>?
    private var resizeTarget: NSRect?
    private var retainedContentHeight: CGFloat = 0
    private var sourceStatus: SourceStatus = .ready
    private var pendingLaunch: UUID?
    /// Results that appeared in a batch for the current request. Only these
    /// match it; any other visible row is a retained, outdated one.
    private var currentMatchIDs: Set<SearchResult.ID> = []
    /// The request whose batch supplied the displayed snapshot, which can
    /// outlive that request while the next query loads its replacement.
    private var displayedResultsGeneration: UUID?
    /// Enter on an outdated row waits for the current request's batches.
    private var heldEnter = false
    private(set) var results: [SearchResult] = []
    private(set) var openFailure: String?
    var query: String { editor.string }
    var contentHeight: CGFloat { panel.contentView?.bounds.height ?? 0 }
    private(set) var resultsScrollOffset: CGFloat = 0
    var statusMessage: String? { resultSurface?.rootView.status }
    var isLoading: Bool { !loadingIndicator.isHidden }
    var modeIconShowsQuery: Bool { modeIcon.showsQuery }
    var mode: CaptureSession.Mode { capture.state.mode }
    var modeIconShowsNote: Bool { modeIcon.glyph == .note }
    var modeLabelText: String? { modeLabel.isHidden ? nil : modeLabel.stringValue }
    var captureMessage: String? { captureNotice.isHidden ? nil : captureNotice.stringValue }
    var resultsVisible: Bool { resultSurface?.isHidden == false }
    var selectedResult: SearchResult? { results.first { $0.id == selectedID } }
    private let diagnostics: Diagnostics
    private var origin: NSRunningApplication?
    private weak var originWindow: NSWindow?
    private weak var originResponder: NSResponder?
    // Membership ends on close, never on minimize or temporary invisibility.
    private var workingWindows: [WorkingWindow: WorkingWindowController] = [:]
    private var localMouse: Any?
    private var globalMouse: Any?
    private var menuDepth = 0
    private var statusItem: NSStatusItem?
    private var shortcutStatus: NSMenuItem?
    private var hotKey: GlobalShortcut?
    private var placementTask: Task<Void, Never>?
    private var currentPlacement: Placement?

    init(diagnostics: Diagnostics = Diagnostics(), search: Search = Search(),
         launchApplication: @escaping @MainActor (URL) async throws -> OpenedApplication = MacInteraction.launch,
         openFile: @escaping @MainActor (URL) async throws -> OpenedApplication = MacInteraction.openFileDestination,
         loadIcon: (@MainActor (URL, CGFloat) async -> ResultIcon?)? = nil,
         collection: Task<CollectionStore, any Error>? = nil, confirmationDuration: Duration = .milliseconds(500),
         frontmostApplication: @escaping @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) {
        self.diagnostics = diagnostics
        self.search = search
        self.collection = collection
        self.confirmationDuration = confirmationDuration
        self.frontmostApplication = frontmostApplication
        self.launchApplication = launchApplication
        self.openFile = openFile
        let icons = ResultIcons(pointSize: BarStyle.resultIconSize)
        self.loadIcon = loadIcon ?? { await icons.icon(for: $0, scale: $1) }
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
        if let button = statusItem?.button {
            // The logo stands in for the name; without the bundle it falls back to text.
            let warning = result == noErr ? "" : " !"
            if let logo = NSImage.hanaStatusLogo {
                button.image = logo
                button.imagePosition = .imageLeading
                button.title = warning
            } else {
                button.title = "Hana" + warning
            }
            button.setAccessibilityLabel(result == noErr ? "Hana" : "Hana, Option+Space unavailable")
        }
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
            origin = frontmostApplication()
            originWindow = origin?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? NSApp.keyWindow : nil
            originResponder = originWindow?.firstResponder
            currentInvocation = invocation
            _ = capture.handle(.invoked)
            clearEditor()
            observeSession(invocation)
            let pointer = NSEvent.mouseLocation
            let displays = NSScreen.screens.map { Display(frame: $0.frame, visibleFrame: $0.visibleFrame) }
            if let window = originWindow, window.isVisible, !window.isMiniaturized {
                applyPlacement(displays: displays, pointer: pointer, focus: .owned(window.frame))
            } else if let origin, origin.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      AXIsProcessTrusted() {
                let processID = origin.processIdentifier
                placementTask = Task { [weak self] in
                    let frame = await Self.focusedWindowWithinDeadline {
                        FocusedWindowGeometry.read(processID: processID)
                    }
                    guard let self, self.currentInvocation == invocation, !Task.isCancelled else { return }
                    self.placementTask = nil
                    self.applyPlacement(displays: displays, pointer: pointer,
                                        focus: frame.map(WindowFocus.accessibility) ?? .unavailable)
                    self.showBar(existing: false, started: started)
                }
                return invocation
            } else {
                applyPlacement(displays: displays, pointer: pointer, focus: .unavailable)
            }
        }
        // A second invocation must not present at stale geometry while AX is pending.
        if placementTask == nil { showBar(existing: existing, started: started) }
        return invocation
    }

    private func showBar(existing: Bool, started: TimeInterval) {
        // Do not activate the process: the nonactivating panel takes key focus
        // while the foreign invocation origin keeps its ordinary activation.
        panel.makeKeyAndOrderFront(nil)
        let accepted = panel.makeFirstResponder(editor)
        record(existing ? "invoke.existing" : "invoke.new", extra: [
            "responderAccepted": accepted,
            "presentationMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000
        ])
    }

    func dismiss(_ invocation: Invocation, reason: DismissalReason) {
        guard currentInvocation == invocation else {
            record("dismiss.stale-ignored")
            return
        }
        record("dismiss.\(reason.rawValue)")
        currentInvocation = nil
        placementTask?.cancel()
        placementTask = nil
        removeSessionObservers()
        panel.orderOut(nil)
        // A save already issued still completes; its outcome can't reach a later invocation.
        confirmationTask?.cancel()
        confirmationTask = nil
        // Discards any unsaved capture: nothing about it outlives the invocation.
        _ = capture.handle(.dismissed)
        clearEditor()
        resetSearch()
        currentPlacement = nil
        // The foreign origin normally never lost activation. Ordering out the
        // nonactivating panel releases its key focus. Never activate an old app
        // over a subsequent user choice, even for Escape. Restoration is best effort.
        if reason == .escape || reason == .saved,
           origin?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           frontmostApplication()?.processIdentifier == origin?.processIdentifier,
           let originWindow, originWindow.isVisible, !originWindow.isMiniaturized {
            originWindow.makeKey()
            if let originResponder { originWindow.makeFirstResponder(originResponder) }
        }
        origin = nil
        originWindow = nil
        originResponder = nil
    }

    /// An invocation-bound destination must not steal focus from a newer session.
    @discardableResult
    func open(_ destination: WorkingWindow, from invocation: Invocation? = nil) -> Bool {
        if let invocation, currentInvocation != invocation {
            record("destination.stale-ignored")
            return false
        }
        if let currentInvocation { dismiss(currentInvocation, reason: .destination) }
        if workingWindows[destination] == nil {
            let controller = WorkingWindowController(destination: destination)
            controller.window?.delegate = self
            workingWindows[destination] = controller
        }
        updateActivationPolicy()
        guard let controller = workingWindows[destination], let window = controller.window else { return false }
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Only explicit destination opening activates the process. Ordinary bar
        // invocation never orders unrelated working windows or changes policy.
        // Name the app we are transferring activation from. Plain NSApp.activate()
        // left foreign full-screen Notes active in the physical destination check.
        // This remains a request; its acknowledgment is not typing-focus proof.
        if let source = NSWorkspace.shared.frontmostApplication {
            let allowed = NSRunningApplication.current.activate(from: source, options: [])
            record("working.activation-request", extra: ["allowed": allowed])
        } else {
            NSApp.activate()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(controller.focusProbe)
        record("working.open", extra: ["destination": destination.rawValue])
        return true
    }

    private func updateActivationPolicy() {
        let desired: NSApplication.ActivationPolicy = workingWindows.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != desired else { return }
        let accepted = NSApp.setActivationPolicy(desired)
        record("policy.changed", extra: ["accepted": accepted])
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let destination = workingWindows.first(where: { $0.value.window === window })?.key else { return }
        workingWindows.removeValue(forKey: destination)
        if originWindow === window { originWindow = nil; originResponder = nil }
        updateActivationPolicy()
        record("working.closed", extra: ["destination": destination.rawValue])
    }

    func windowDidMiniaturize(_ notification: Notification) { record("working.minimized") }
    func windowDidDeminiaturize(_ notification: Notification) { record("working.deminiaturized") }
    func windowDidBecomeKey(_ notification: Notification) { record("working.becameKey") }

    @objc private func openWorkingWindow(_ sender: NSMenuItem) {
        guard let destination = WorkingWindow(rawValue: sender.tag) else { return }
        open(destination, from: currentInvocation)
    }

    @objc private func minimizeAll() {
        for destination in WorkingWindow.allCases {
            if let window = workingWindows[destination]?.window, !window.isMiniaturized { window.miniaturize(nil) }
        }
        record("working.minimize-all")
    }

    @objc private func closeAll() {
        for controller in Array(workingWindows.values) { controller.close() }
        record("working.close-all")
    }

    private func configurePanel() {
        panel.openDestination = { [weak self] destination in
            guard let self, let invocation = self.currentInvocation else { return }
            self.open(destination, from: invocation)
        }
        panel.title = "Hana Search"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        // Only the pixels outside the rounded bezel are transparent. The bar is
        // always light, so Dark Mode must not darken the material or colors.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .aqua)
        let bezel = NSVisualEffectView(frame: panel.contentView!.bounds)
        bezel.material = .popover
        bezel.blendingMode = .behindWindow
        // The panel never activates Hana, so following window state would render it inactive.
        bezel.state = .active
        bezel.maskImage = .roundedMask(radius: BarStyle.bezelRadius)
        panel.contentView = bezel
        let tint = NSView(frame: bezel.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        tint.layer?.cornerRadius = BarStyle.bezelRadius
        bezel.addSubview(tint)

        // One card holds the input and, below it, the results. It grows with the
        // panel while the input stays pinned to its top.
        let card = NSView.card(frame: NSRect(
            x: BarStyle.inset, y: BarStyle.inset,
            width: BarStyle.width - 2 * BarStyle.inset, height: BarStyle.inputHeight))
        card.autoresizingMask = [.width, .height]
        bezel.addSubview(card)
        modeIcon.autoresizingMask = [.minYMargin]
        card.addSubview(modeIcon)

        // Ends where the results' type labels end.
        let labelTrailing = BarStyle.cardPadding + BarStyle.resultIconInset
        loadingIndicator.frame = NSRect(x: card.frame.width - labelTrailing - 16, y: 22, width: 16, height: 16)
        loadingIndicator.autoresizingMask = [.minXMargin, .minYMargin]
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.isHidden = true
        loadingIndicator.setAccessibilityLabel("Searching")
        card.addSubview(loadingIndicator)

        modeLabel.font = BarStyle.modeLabelFont
        modeLabel.textColor = BarStyle.secondaryColor
        modeLabel.sizeToFit()
        modeLabel.frame.origin = NSPoint(x: card.frame.width - labelTrailing - modeLabel.frame.width,
                                         y: 30 - modeLabel.frame.height / 2)
        modeLabel.autoresizingMask = [.minXMargin, .minYMargin]
        modeLabel.isHidden = true
        card.addSubview(modeLabel)

        captureNotice.font = BarStyle.modeLabelFont
        captureNotice.textColor = BarStyle.secondaryColor
        captureNotice.maximumNumberOfLines = 1
        captureNotice.lineBreakMode = .byTruncatingTail
        captureNotice.autoresizingMask = [.width, .minYMargin]
        captureNotice.isHidden = true
        card.addSubview(captureNotice)

        let scroll = editorScroll
        scroll.frame = NSRect(x: BarStyle.textInset, y: BarStyle.editorTopInset,
                              width: card.frame.width - BarStyle.textInset - 44, height: BarStyle.editorHeight)
        scroll.autoresizingMask = [.width, .minYMargin]
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        editor.frame = scroll.bounds
        editor.minSize = NSSize(width: 0, height: BarStyle.editorHeight)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.font = BarStyle.font
        editor.textColor = BarStyle.textColor
        editor.typingAttributes = BarStyle.textAttributes
        editor.insertionPointColor = BarStyle.textColor
        editor.backgroundColor = .white
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        // Captures are Markdown: nothing may rewrite its punctuation or spacing.
        editor.smartInsertDeleteEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.setAccessibilityLabel("Search")
        editor.setAccessibilityPlaceholderValue("Search")
        editor.delegate = self
        editor.escape = { [weak self] in
            guard let self, let invocation = self.currentInvocation else { return }
            self.dismiss(invocation, reason: .escape)
        }
        editor.compositionChanged = { [weak self] in self?.updateModeIcon() }
        editor.shouldInsert = { [weak self] text, range, provenance in
            self?.shouldInsert(text, replacing: range, provenance: provenance) ?? true
        }
        scroll.documentView = editor
        card.addSubview(scroll)

        let results = NSHostingView(rootView: SearchResultsView())
        results.frame = .zero
        results.autoresizingMask = [.width, .minYMargin]
        results.isHidden = true
        card.addSubview(results)
        resultSurface = results
    }

    private func clearEditor() {
        editor.isEditable = true
        editor.unmarkText()
        editor.string = ""
        editor.typingAttributes = BarStyle.textAttributes
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.undoManager?.removeAllActions()
        modeIcon.setShowsQuery(false, animated: false)
        applyModePresentation(animated: false)
    }

    private func show(_ mode: CaptureSession.Mode) {
        record("capture.mode", extra: ["mode": mode.rawValue])
        resetSearch()
        applyModePresentation(animated: panel.isVisible)
        // Search shows the results for the text it kept.
        if mode == .search { updateQuery(editor.string) } else { renderResults() }
    }

    private func applyModePresentation(animated: Bool) {
        let note = mode == .note
        editor.placeholder = note ? nil : "Search"
        editor.setAccessibilityLabel(note ? "Note" : "Search")
        editor.setAccessibilityPlaceholderValue(note ? nil : "Search")
        modeLabel.isHidden = !note
        setModeLabel("Note")
        // Search's glyph follows its query; clearing the editor restores the logo.
        if note { modeIcon.setGlyph(.note, animated: animated) } else { updateModeIcon() }
        editorScroll.hasVerticalScroller = note
        guard let card = editorScroll.superview else { return }
        // Note leaves room for its label. The height follows the text; layout sets it.
        let trailing = note ? card.bounds.width - modeLabel.frame.minX + 8 : 44
        editorScroll.frame = NSRect(x: BarStyle.textInset, y: editorScroll.frame.minY,
                                    width: card.bounds.width - BarStyle.textInset - trailing, height: editorScroll.frame.height)
    }

    private func applyPlacement(displays: [Display], pointer: CGPoint, focus: WindowFocus) {
        currentPlacement = Self.placement(displays: displays, pointer: pointer, focus: focus)
        guard let placement = currentPlacement else { return }
        setPanelFrame(placement.frame(height: BarStyle.collapsedHeight), animated: false)
        renderResults()
        record("placement.\(placement.source)", extra: ["visibleFrame": NSStringFromRect(placement.visibleFrame)])
    }

    private func belongsToSearch(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window === panel { return true }
        return belongsToSearch(window.parent) || belongsToSearch(window.sheetParent)
    }

    private func observeSession(_ invocation: Invocation) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMouse = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, !self.belongsToSearch(event.window), self.menuDepth == 0 {
                    self.dismiss(invocation, reason: .outsideClick)
                }
            }
            return event
        }
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                // Global monitors exclude this app's events. A click delivered
                // by another app is outside even if our menu-end notice is late.
                guard let self else { return }
                self.dismiss(invocation, reason: .outsideClick)
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appChanged(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(environmentChanged(_:)), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(environmentChanged(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(environmentChanged(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(environmentChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
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

    @objc private func environmentChanged(_ notification: Notification) {
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
        addWorkingWindowControls(to: menu, shortcuts: false)
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
        let windows = NSMenu(title: "Window")
        addWorkingWindowControls(to: windows, shortcuts: true)
        windows.addItem(.separator())
        windows.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windows.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windows
        main.addItem(windowItem)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }

    private func addWorkingWindowControls(to menu: NSMenu, shortcuts: Bool) {
        for destination in WorkingWindow.allCases {
            let item = NSMenuItem(title: "Open \(destination.title) — validation only",
                                  action: #selector(openWorkingWindow(_:)),
                                  keyEquivalent: shortcuts ? String(destination.rawValue) : "")
            item.tag = destination.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, action) in [("Minimize all working windows", #selector(minimizeAll)),
                                ("Close all working windows", #selector(closeAll))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }

    func textDidChange(_ notification: Notification) {
        record("editor.changed")
        _ = capture.handle(.edited(text: editor.string, selection: editor.selectedRange()))
        if mode == .search { updateQuery(editor.string) } else { renderResults() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        _ = capture.handle(.edited(text: editor.string, selection: editor.selectedRange()))
    }

    /// The editor asks before applying each native insertion. Returns false when
    /// the session consumed it, so it never becomes text or an undoable edit.
    private func shouldInsert(_ text: String, replacing range: NSRange, provenance: CaptureSession.Provenance) -> Bool {
        guard currentInvocation != nil else { return true }
        var applies = true
        for effect in capture.handle(.insert(text, replacing: range, provenance: provenance)) {
            switch effect {
            case .consumeInsertion: applies = false
            default: perform(effect)
            }
        }
        return applies
    }

    /// Enter in Note. Repeated Enter while saving, and Enter during the
    /// confirmation, do nothing: the session has already frozen the text.
    private func submitCapture() {
        let effects = capture.handle(.submit)
        if effects.isEmpty, capture.state.notice == .blank { record("capture.refused-blank") }
        effects.forEach(perform)
        renderResults()
    }

    private func perform(_ effect: CaptureSession.Effect) {
        guard let invocation = currentInvocation else { return }
        switch effect {
        case .enterMode(let mode): show(mode)
        case .save(let operation, let body): save(body, operation: operation, from: invocation)
        case .confirmSaved:
            setModeLabel("Saved")
            let duration = confirmationDuration
            // Focus returns to the invocation origin when the confirmation ends.
            confirmationTask = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard let self, !Task.isCancelled, self.currentInvocation == invocation else { return }
                self.dismiss(invocation, reason: .saved)
            }
        // Only `shouldInsert` can drop an insertion.
        case .consumeInsertion: break
        }
    }

    /// Issues the session's one save. Its outcome reaches only the invocation
    /// and operation that requested it.
    private func save(_ body: String, operation: UUID, from invocation: Invocation) {
        record("capture.save-request")
        let collection = collection
        Task { [weak self] in
            let store: CollectionStore
            do {
                guard let collection else { throw CollectionStoreError.missingCollection }
                store = try await collection.value
            } catch {
                self?.finishSave(.saveFailed(.collectionUnavailable), operation: operation, invocation: invocation, error: error)
                return
            }
            do {
                _ = try await store.perform(.createNote(operation: operation, body: body), in: store.generation)
                self?.finishSave(.saved, operation: operation, invocation: invocation, error: nil)
            } catch {
                self?.finishSave(.saveFailed(.failed), operation: operation, invocation: invocation, error: error)
            }
        }
    }

    private func finishSave(_ outcome: CaptureSession.Event, operation: UUID, invocation: Invocation, error: (any Error)?) {
        guard currentInvocation == invocation, capture.operation == operation else {
            record("capture.stale-outcome")
            return
        }
        if let error {
            // Classification only: no text, paths or localized descriptions.
            let classification = (error as? CollectionStoreError).map { String(describing: $0) }
                ?? "\((error as NSError).domain):\((error as NSError).code)"
            record(outcome == .saveFailed(.collectionUnavailable) ? "capture.collection-unavailable" : "capture.save-failed",
                   extra: ["error": classification])
        } else {
            record("capture.saved")
        }
        capture.handle(outcome).forEach(perform)
        renderResults()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        // Backspace at the start of a capture returns to Search instead of deleting.
        if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
            let effects = capture.handle(.deleteBackward)
            effects.forEach(perform)
            return !effects.isEmpty
        }
        if mode == .note {
            // Shift+Enter writes a new line; plain Enter saves.
            guard commandSelector == #selector(NSResponder.insertNewline(_:)), !editor.shiftHeld else { return false }
            submitCapture()
            return true
        }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)):
            requestSelectedOpen()
        default: return false
        }
        return true
    }

    /// Native editor changes and callers use the same query-to-batches path.
    func updateQuery(_ text: String) {
        guard currentInvocation != nil else { return }
        if editor.string != text {
            editor.string = text
            _ = capture.handle(.edited(text: text, selection: editor.selectedRange()))
        }
        // Note's text is not a query.
        guard mode == .search else { return renderResults() }
        updateModeIcon()
        searchTask?.cancel()
        // A new query owns a new open intent; an old acknowledgment cannot
        // block Enter or report an error into this context.
        pendingLaunch = nil
        heldEnter = false
        let request = Search.Request(text: CaptureSession.searchQuery(for: text))
        self.request = request
        userMovedSelection = false
        openFailure = nil
        let stream = search.search(request)
        currentMatchIDs = Set(stream.initial.results.map(\.id))
        // Keep the displayed snapshot intact until a source delivers its
        // replacement. An edit alone must not remove nonmatching rows.
        if results.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = stream.initial.results
            displayedResultsGeneration = request.generation
        }
        selectedID = results.first?.id
        icons = icons.filter { id, _ in results.contains { $0.id == id } }
        sourceStatus = stream.initial.appStatus
        fileStatus = stream.initial.fileStatus
        // Interrupt a preceding finished batch's shrink at the actual current
        // height; holding its smaller target would keep shrinking during typing.
        let editorGrowth = editorScroll.frame.height - BarStyle.editorHeight
        retainedContentHeight = max(retainedContentHeight, contentHeight - BarStyle.collapsedHeight - editorGrowth - BarStyle.cardPadding)
        renderResults()
        let started = ProcessInfo.processInfo.systemUptime
        searchTask = Task { [weak self] in
            for await batch in stream.updates {
                guard let self, self.request?.generation == batch.generation,
                      self.currentInvocation != nil, !Task.isCancelled else { continue }
                self.sourceStatus = batch.appStatus
                self.fileStatus = batch.fileStatus
                self.currentMatchIDs.formUnion(batch.results.map(\.id))
                // Empty or cache-only intermediate batches are not a
                // replacement: a source has yet to deliver fresh matches.
                if batch.hasFreshResults || (batch.appStatus != .loading && batch.fileStatus != .loading) {
                    self.results = batch.results
                    self.displayedResultsGeneration = batch.generation
                    self.icons = self.icons.filter { id, _ in batch.results.contains { $0.id == id } }
                    if !self.userMovedSelection || !batch.results.contains(where: { $0.id == self.selectedID }) {
                        self.selectedID = batch.results.first?.id
                        self.userMovedSelection = false
                    }
                }
                self.renderResults()
                if self.heldEnter { self.releaseHeldEnter() }
                self.record("search.batch", extra: ["resultCount": batch.results.count, "appStatus": batch.appStatus.rawValue, "fileStatus": batch.fileStatus.rawValue,
                    "applicationCount": batch.results.filter { $0.kind == .application }.count,
                    "fileCount": batch.results.filter { $0.kind != .application }.count,
                    "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000])
            }
        }
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let index = selectedID.flatMap { id in results.firstIndex { $0.id == id } }
        let next = index.map { min(results.count - 1, max(0, $0 + offset)) } ?? (offset < 0 ? results.count - 1 : 0)
        selectedID = results[next].id
        userMovedSelection = true
        renderResults()
        record("search.selection", extra: ["index": next])
    }

    /// Returns nil when nothing was opened now, including when Enter is held
    /// because the selected row does not match the current request.
    @discardableResult
    func requestSelectedOpen() -> Task<Void, Never>? {
        guard let invocation = currentInvocation, let destination = selectedResult, pendingLaunch == nil else { return nil }
        // Enter again after navigating to a matching row opens it at once.
        guard currentMatchIDs.contains(destination.id) else {
            heldEnter = true
            openFailure = nil
            renderResults()
            record("launch.held", extra: ["destinationKind": destination.typeLabel])
            return nil
        }
        heldEnter = false
        return openResult(destination, from: invocation)
    }

    /// Opens the row selected under the usual rules once it matches the
    /// current request; both sources finishing without one cancels the hold.
    private func releaseHeldEnter() {
        guard let invocation = currentInvocation else { return }
        if let destination = selectedResult, currentMatchIDs.contains(destination.id) {
            heldEnter = false
            openResult(destination, from: invocation)
        } else if sourceStatus != .loading && fileStatus != .loading {
            heldEnter = false
            renderResults()
            record("launch.held-cancelled")
        }
    }

    @discardableResult
    private func openResult(_ destination: SearchResult, from invocation: Invocation) -> Task<Void, Never> {
        let operation = UUID()
        pendingLaunch = operation
        let generation = request?.generation
        openFailure = nil
        renderResults()
        record("launch.request", extra: ["destinationKind": destination.typeLabel])
        return Task {
            guard currentInvocation == invocation, pendingLaunch == operation else { return }
            do {
                let opened = try await (destination.kind == .application ? launchApplication(destination.url) : openFile(destination.url))
                guard currentInvocation == invocation, pendingLaunch == operation else {
                    record("launch.stale-acknowledgment")
                    return
                }
                pendingLaunch = nil
                search.recordOpened(destination.id)
                record("launch.acknowledged")
                guard request?.generation == generation else { renderResults(); return }
                // No await between the fence, dismissal, and activation. The
                // workspace open itself requested no activation, so an obsolete
                // completion cannot initiate a late focus/Space transfer.
                dismiss(invocation, reason: .destination)
                let accepted = opened.activate()
                record("launch.activation-request", extra: ["accepted": accepted])
            } catch {
                guard currentInvocation == invocation, pendingLaunch == operation else { return }
                pendingLaunch = nil
                if request?.generation == generation {
                    openFailure = Self.openFailureMessage(error)
                }
                renderResults()
                // Numeric classification only; localized errors may expose paths.
                let failure = error as NSError
                record("launch.failed", extra: ["errorDomain": failure.domain, "errorCode": failure.code])
            }
        }
    }

    private static func openFailureMessage(_ error: Error) -> String {
        let error = error as NSError
        if (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
            || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code)) {
            return "Access was denied. Check this destination’s permissions in Finder, then retry."
        }
        if (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
            return "This destination is no longer available at this location. Check it in Finder, then search again."
        }
        return "macOS couldn’t open this destination. Check it in Finder and its default app, then retry."
    }

    private static func launch(_ url: URL) async throws -> OpenedApplication {
        guard FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.promptsUserIfNeeded = false
        let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return OpenedApplication {
            guard let source = NSWorkspace.shared.frontmostApplication else { return application.activate(options: []) }
            return application.activate(from: source, options: [])
        }
    }

    private static func openFileDestination(_ url: URL) async throws -> OpenedApplication {
        // Revalidate off the input actor: a disconnected volume must not block typing.
        try await Task.detached(priority: .userInitiated) {
            guard Search.eligible(url) else { throw CocoaError(.fileReadUnknown) }
            // Keep filesystem errors intact. Boolean existence/readability checks
            // erase the distinction between missing resources and access denial.
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        }.value
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.promptsUserIfNeeded = false
        let application = try await NSWorkspace.shared.open(url, configuration: configuration)
        return OpenedApplication {
            guard let source = NSWorkspace.shared.frontmostApplication else { return application.activate(options: []) }
            return application.activate(from: source, options: [])
        }
    }

    /// Composition counts as a query: the placeholder is already hidden.
    private func updateModeIcon() {
        guard mode == .search else { return }
        modeIcon.setShowsQuery(!editor.string.isEmpty || editor.hasMarkedText(), animated: panel.isVisible)
    }

    private func resetSearch() {
        searchTask?.cancel()
        searchTask = nil
        request = nil
        // Invalidate an already-issued native open; it cannot be recalled, but
        // its acknowledgment must never close a subsequent invocation.
        pendingLaunch = nil
        heldEnter = false
        results = []
        displayedResultsGeneration = nil
        icons = [:]
        selectedID = nil
        openFailure = nil
        sourceStatus = .ready
        fileStatus = .ready
        renderResults()
    }

    /// Animates only while visible. Instant changes still go through the animator
    /// to cancel an in-flight resize, but the animator applies them only later.
    private func setPanelFrame(_ frame: NSRect, animated: Bool) {
        let animates = animated && panel.isVisible && frame != panel.frame
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Re-renders that keep the target (icons, selection) must not restart the curve.
        if animates, frame == resizeTarget { return }
        resizeTarget = animates ? frame : nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animates ? BarStyle.resizeDuration : 0
            context.timingFunction = BarStyle.easeOut
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.resizeTarget == frame { self.resizeTarget = nil }
                self.panel.invalidateShadow()
            }
        }
        if !animates { panel.setFrame(frame, display: true) }
        panel.invalidateShadow()
    }

    private func renderResults() {
        guard mode == .search else { return layoutNote() }
        // Capture notices belong to Note; returning to Search leaves them behind.
        captureNotice.isHidden = true
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let loading = hasQuery && (sourceStatus == .loading || fileStatus == .loading)
        loadingIndicator.isHidden = !loading
        if loading { loadingIndicator.startAnimation(nil) } else { loadingIndicator.stopAnimation(nil) }
        let status: String?
        if !hasQuery { status = nil }
        else if let openFailure { status = openFailure }
        else if pendingLaunch != nil || heldEnter { status = "Opening selected destination…" }
        else if sourceStatus == .failed || fileStatus == .failed {
            status = !results.isEmpty && displayedResultsGeneration == request?.generation
                ? "A search source reported a failure. Available results are shown; retry the search."
                : "A search source reported a failure. Retry the search."
        }
        else if sourceStatus == .partial || fileStatus == .partial { status = "Partial search results — refine your query for more specific matches." }
        else if loading { status = nil }
        else { status = results.isEmpty ? "No matches returned. Indexing and access can limit results." : nil }
        // Results extend the card downward below the input row, so the input
        // position never moves while expanding.
        let needed = hasQuery ? SearchResultsView.height(rowCount: results.count, hasStatus: status != nil) : 0
        let finished = sourceStatus != .loading && fileStatus != .loading
        retainedContentHeight = !hasQuery || finished ? needed : max(retainedContentHeight, needed)
        let content = retainedContentHeight
        // Text kept from a multiline note stays fully visible above the results.
        let editorHeight = self.editorHeight
        let editorGrowth = editorHeight - BarStyle.editorHeight
        let frame = currentPlacement?.frame(
            height: BarStyle.collapsedHeight + editorGrowth + (content > 0 ? BarStyle.cardPadding + content : 0)) ?? panel.frame
        setPanelFrame(frame, animated: true)
        pinEditor(height: editorHeight)
        // Results are laid out at their final size, pinned under the input, so
        // the card's clip reveals them as it grows instead of moving them. The
        // surface runs to the card's trailing edge so the scroll thumb can sit in
        // the padding beside the rows.
        if let resultSurface, let card = resultSurface.superview {
            let height = max(0, frame.height - BarStyle.collapsedHeight - editorGrowth - BarStyle.cardPadding)
            resultSurface.frame = NSRect(x: BarStyle.cardPadding,
                                         y: card.bounds.height - BarStyle.inputHeight - editorGrowth - height,
                                         width: max(0, frame.width - 2 * BarStyle.inset - BarStyle.cardPadding),
                                         height: height)
            resultSurface.isHidden = content == 0
        }
        resultSurface?.rootView = SearchResultsView(results: results, selectedID: selectedID, status: status, icons: icons,
            scrollResetID: request?.generation, followsFirstResult: !userMovedSelection,
            scrollOffsetChanged: { [weak self] in self?.resultsScrollOffset = $0 },
            select: { [weak self] id in
                guard let self, self.results.contains(where: { $0.id == id }) else { return }
                self.selectedID = id
                self.userMovedSelection = true
                self.renderResults()
                self.panel.makeFirstResponder(self.editor)
            }, rowAppeared: { [weak self] id in self?.requestIcon(id) })
    }

    /// Note grows with its text to a maximum height and then scrolls. Like the
    /// results, it extends the card downward so the input never moves; placement
    /// shifts the bar only to keep it on screen.
    private func layoutNote() {
        loadingIndicator.isHidden = true
        loadingIndicator.stopAnimation(nil)
        resultSurface?.isHidden = true
        retainedContentHeight = 0
        // Submitted text is frozen until a failure returns it for editing.
        editor.isEditable = capture.state.phase == .editing
        let notice = capture.state.notice.map(Self.noticeMessage)
        captureNotice.stringValue = notice ?? ""
        captureNotice.isHidden = notice == nil
        let noticeHeight = notice == nil ? 0 : BarStyle.noticeHeight
        let height = editorHeight
        let frame = currentPlacement?.frame(
            height: BarStyle.collapsedHeight + height - BarStyle.editorHeight + noticeHeight) ?? panel.frame
        setPanelFrame(frame, animated: true)
        pinEditor(height: height)
        guard let card = editorScroll.superview else { return }
        captureNotice.frame = NSRect(x: BarStyle.textInset, y: editorScroll.frame.minY - noticeHeight,
                                     width: card.bounds.width - BarStyle.textInset - BarStyle.cardPadding - BarStyle.resultIconInset,
                                     height: noticeHeight)
    }

    /// The editor is as tall as its text, from one line up to Note's maximum,
    /// in every mode, so switching modes never hides a line.
    private var editorHeight: CGFloat {
        min(BarStyle.noteMaxTextHeight, max(BarStyle.editorHeight, textHeight))
    }

    /// Laid out at the final height, pinned under the card's top, so the card
    /// reveals it as it grows.
    private func pinEditor(height: CGFloat) {
        guard let card = editorScroll.superview else { return }
        editorScroll.frame = NSRect(x: editorScroll.frame.minX, y: card.bounds.height - BarStyle.editorTopInset - height,
                                    width: editorScroll.frame.width, height: height)
    }

    private static func noticeMessage(_ notice: CaptureSession.Notice) -> String {
        switch notice {
        case .blank: "Write something to save this note."
        case .collectionUnavailable: "The collection couldn’t be opened, so notes can’t be saved right now. Your text is kept."
        case .failed: "This note couldn’t be saved. Your text is kept."
        }
    }

    /// The label ends where the results' type labels end; Note's text stops short of it.
    private func setModeLabel(_ text: String) {
        guard let card = modeLabel.superview else { return }
        modeLabel.stringValue = text
        modeLabel.sizeToFit()
        let labelTrailing = BarStyle.cardPadding + BarStyle.resultIconInset
        modeLabel.frame.origin = NSPoint(x: card.bounds.width - labelTrailing - modeLabel.frame.width,
                                         y: card.bounds.height - BarStyle.inputHeight + 30 - modeLabel.frame.height / 2)
        guard mode == .note else { return }
        editorScroll.frame.size.width = modeLabel.frame.minX - 8 - BarStyle.textInset
    }

    private var textHeight: CGFloat {
        let inset = 2 * editor.textContainerInset.height
        if let layout = editor.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
            return layout.usageBoundsForTextContainer.height + inset
        }
        // Overriding drawing makes AppKit give this editor TextKit 1. Its frame
        // lags behind the text, so measure the laid-out lines instead.
        guard let layout = editor.layoutManager, let container = editor.textContainer else { return editor.frame.height }
        layout.ensureLayout(for: container)
        return layout.usedRect(for: container).height + inset
    }

    /// Called as a row is about to appear. A late icon only fills the cache:
    /// it never changes results, selection, status or the batches.
    private func requestIcon(_ id: SearchResult.ID) {
        guard let result = results.first(where: { $0.id == id }), result.kind == .application,
              icons[id] == nil, iconRequests.insert(id).inserted else { return }
        let scale = panel.backingScaleFactor
        Task { [weak self, loadIcon] in
            let icon = await loadIcon(result.url, scale)
            guard let self else { return }
            self.iconRequests.remove(id)
            guard self.results.contains(where: { $0.id == id }) else { return }
            guard let icon else { self.record("search.icon-unavailable"); return }
            self.icons[id] = icon
            self.renderResults()
        }
    }

    private func record(_ event: String, extra: [String: Any] = [:]) {
        guard diagnostics.isEnabled else { return }
        var state: [String: Any] = [
            "panelStyle": panel.styleMask.rawValue,
            "working": WorkingWindow.allCases.compactMap { destination -> [String: Any]? in
                guard let window = workingWindows[destination]?.window else { return nil }
                return ["id": destination.rawValue, "minimized": window.isMiniaturized,
                        "visible": window.isVisible, "key": window.isKeyWindow,
                        "onActiveSpace": window.isOnActiveSpace]
            },
            "session": currentInvocation?.id.uuidString ?? "none",
            "policy": NSApp.activationPolicy() == .accessory ? "accessory" : NSApp.activationPolicy() == .regular ? "regular" : "prohibited",
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
    var openDestination: ((WorkingWindow) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers, let value = Int(key),
           let destination = WorkingWindow(rawValue: value) {
            openDestination?(destination)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SearchEditor: NSTextView {
    var escape: (() -> Void)?
    var compositionChanged: (() -> Void)?
    /// Asked before each native insertion is applied, with where it came from.
    /// False drops it: no text change and no undo entry.
    var shouldInsert: ((String, NSRange, CaptureSession.Provenance) -> Bool)?
    var placeholder: String? = "Search" {
        didSet { needsDisplay = true }
    }
    /// Whether the key event being handled has Shift down.
    private(set) var shiftHeld = false
    private var provenance: CaptureSession.Provenance?
    override var needsPanelToBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !hasMarkedText() {
            escape?()
            return
        }
        shiftHeld = event.modifierFlags.contains(.shift)
        defer { shiftHeld = false }
        super.keyDown(with: event)
    }

    /// Provenance comes from the native operation performing the edit, never
    /// from key codes. The outermost operation names it: AppKit may insert a
    /// paste or drop through the same paths typing uses.
    private func performing<T>(_ provenance: CaptureSession.Provenance, _ edit: () -> T) -> T {
        let outer = self.provenance
        if outer == nil { self.provenance = provenance }
        defer { self.provenance = outer }
        return edit()
    }

    /// The text-input insertion path. Committing marked text is not typing. Key
    /// input replaces the selection without naming a range; an explicit range
    /// (accent menu, Emoji & Symbols, dictation) is uncertain, so literal.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let provenance: CaptureSession.Provenance = hasMarkedText() ? .compositionCommit
            : replacementRange.location == NSNotFound ? .typed : .programmatic
        performing(provenance) { super.insertText(string, replacementRange: replacementRange) }
    }

    override func paste(_ sender: Any?) { performing(.paste) { super.paste(sender) } }
    override func pasteAsPlainText(_ sender: Any?) { performing(.paste) { super.pasteAsPlainText(sender) } }
    override func pasteAsRichText(_ sender: Any?) { performing(.paste) { super.pasteAsRichText(sender) } }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        performing(.drop) { super.performDragOperation(sender) }
    }

    /// Insertions pass here before super registers them for undo. Undo and redo
    /// replay theirs without asking; if they ever ask, they stay literal.
    override func shouldChangeText(in range: NSRange, replacementString: String?) -> Bool {
        if let replacementString {
            let provenance: CaptureSession.Provenance = undoManager?.isUndoing == true ? .undo
                : undoManager?.isRedoing == true ? .redo : self.provenance ?? .programmatic
            guard shouldInsert?(replacementString, range, provenance) ?? true else { return false }
        }
        return super.shouldChangeText(in: range, replacementString: replacementString)
    }

    // NSTextView has no public placeholder. Hide it during composition too,
    // because marked text is not yet part of `string`.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let placeholder, string.isEmpty, !hasMarkedText() else { return }
        NSAttributedString(string: placeholder, attributes: BarStyle.placeholderAttributes)
            .draw(at: textContainerOrigin)
    }

    override var string: String {
        didSet { needsDisplay = true }
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        performing(.composition) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
        needsDisplay = true
        compositionChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
        compositionChanged?()
    }
}
