import AppKit
import ApplicationServices
import SwiftUI

/// Owns the native Search lifetime. Callers carry Invocation into any delayed
/// completion so an obsolete operation cannot dismiss a newer session.
@MainActor
final class MacInteraction: NSObject, NSTextViewDelegate, NSWindowDelegate, NSMenuDelegate {
    struct Invocation: Equatable {
        fileprivate let id = UUID()
    }

    /// A destination that passed revalidation, so the bar can close. `open`
    /// issues the native open, whose acknowledgment can wait until a slow app
    /// finishes launching; it yields the exact running instance's activation.
    struct ValidatedDestination {
        let open: @MainActor () async throws -> @MainActor () -> Bool

        init(open: @escaping @MainActor () async throws -> @MainActor () -> Bool) {
            self.open = open
        }

        /// One whose native open is already acknowledged.
        init(activate: @escaping @MainActor () -> Bool) {
            open = { activate }
        }
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
    /// Task's Inbox/Today choice, before its mode label. Tab toggles it too.
    /// Internal so tests can click it.
    let destinationSelector = NSHostingView(rootView: SegmentedControl(
        labels: TaskPlacement.allCases.map(\.title), accessibilityTitle: "Task destination"))
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
    private let launchApplication: @MainActor (URL) async throws -> ValidatedDestination
    private let openFile: @MainActor (URL) async throws -> ValidatedDestination
    private let loadIcon: @MainActor (URL, CGFloat) async -> ResultIcon?
    private var iconRequests: Set<SearchResult.ID> = []
    /// Icons for current results only; Result Icons owns the bounded cache.
    private(set) var icons: [SearchResult.ID: ResultIcon] = [:]
    private var fileStatus: SourceStatus = .ready
    private var searchTask: Task<Void, Never>?
    private var request: Search.Request?
    /// A match or a capture suggestion; nil only while there are no rows.
    private(set) var selectedRow: SearchRow.ID?
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
    /// What Enter was pressed on while it waits for the current request's batches.
    private enum HeldEnter {
        /// An outdated row.
        case result
        /// An unnavigated suggestion while a source could still deliver a match.
        case suggestion
    }
    private var heldEnter: HeldEnter?
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
    var modeIconShowsTask: Bool { modeIcon.glyph == .task }
    var taskDestination: TaskPlacement { capture.state.destination }
    var destinationSelectorTitle: String? {
        destinationSelector.isHidden ? nil : destinationSelector.rootView.labels[destinationSelector.rootView.selection]
    }
    var modeLabelText: String? { modeLabel.isHidden ? nil : modeLabel.stringValue }
    var placeholderText: String? { editor.visiblePlaceholder }
    var captureMessage: String? { captureNotice.isHidden ? nil : captureNotice.stringValue }
    var resultsVisible: Bool { resultSurface?.isHidden == false }
    var selectedResult: SearchResult? {
        guard case .result(let id) = selectedRow else { return nil }
        return results.first { $0.id == id }
    }
    /// Search's list: every match, then New note and New task while it has a query.
    var rows: [SearchRow] {
        guard mode == .search else { return [] }
        return results.map(SearchRow.result) + (hasQuery ? CaptureSession.Suggestion.allCases.map(SearchRow.suggestion) : [])
    }
    private var hasQuery: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private let diagnostics: Diagnostics
    let automaticSwitchOptions: AutomaticSwitchOptionsStore
    let automaticSwitchDiagnostics: AutomaticSwitchDiagnostics
    private(set) var automaticSwitchSessionOptions = AutomaticSwitchOptions()
    private(set) var automaticSwitchMenu: NSMenu?
    private var automaticSwitchToggle: NSMenuItem?
    private var automaticSwitchCountItems: [NSMenuItem] = []
    private var automaticSwitchReset: NSMenuItem?
    /// Nil by default: persisted preferences cannot make tests call real models.
    private let classifierFactory: (@MainActor (AutomaticSwitchOptions) -> (any Classifier)?)?
    private let classifierServices: ClassifierServices?
    private var classifierMenuController: ClassifierMenuController?
    private var classifier: (any Classifier)?
    private var automaticSwitch: AutomaticSwitch?
    private var classificationTasks: [UUID: Task<Void, Never>] = [:]
    private var automaticSwitchTicker: Task<Void, Never>?
    private var titleObservation: Task<Void, Never>?
    private var titleSource: CollectionTitleSource?
    private var gateTitles = StrongMatchGate.Titles(status: .unavailable)
    private var gateResults: [SearchResult] = []
    private var automaticSwitchChoices: [(NSMenuItem, (AutomaticSwitchOptions) -> Bool)] = []
    private var automaticSwitchMutations: [(inout AutomaticSwitchOptions) -> Void] = []
    private var origin: NSRunningApplication?
    private weak var originWindow: NSWindow?
    private weak var originResponder: NSResponder?
    // Membership ends on close, never on minimize or temporary invisibility.
    private var workingWindows: [WorkingWindow: WorkingWindowController] = [:]
    var mainWindowPresentation: MainWindowPresentation? { workingWindows[.main]?.presentation }
    func window(for destination: WorkingWindow) -> NSWindow? { workingWindows[destination]?.window }
    private var localMouse: Any?
    private var globalMouse: Any?
    private var menuDepth = 0
    private var statusItem: NSStatusItem?
    var menuBarMenu: NSMenu? { statusItem?.menu }
    private var shortcutStatus: NSMenuItem?
    private var hotKey: GlobalShortcut?
    private var placementTask: Task<Void, Never>?
    private var currentPlacement: Placement?

    init(diagnostics: Diagnostics = Diagnostics(), search: Search = Search(),
         launchApplication: @escaping @MainActor (URL) async throws -> ValidatedDestination = MacInteraction.launch,
         openFile: @escaping @MainActor (URL) async throws -> ValidatedDestination = MacInteraction.openFileDestination,
         loadIcon: (@MainActor (URL, CGFloat) async -> ResultIcon?)? = nil,
         collection: Task<CollectionStore, any Error>? = nil, confirmationDuration: Duration = .milliseconds(500),
         automaticSwitchOptions: AutomaticSwitchOptionsStore = AutomaticSwitchOptionsStore(),
         automaticSwitchDiagnostics: AutomaticSwitchDiagnostics = AutomaticSwitchDiagnostics(),
         classifierServices: ClassifierServices? = nil,
         classifierFactory: (@MainActor (AutomaticSwitchOptions) -> (any Classifier)?)? = nil,
         frontmostApplication: @escaping @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) {
        self.diagnostics = diagnostics
        self.automaticSwitchOptions = automaticSwitchOptions
        self.automaticSwitchDiagnostics = automaticSwitchDiagnostics
        self.classifierFactory = classifierFactory
        self.classifierServices = classifierServices
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
        for controller in Array(workingWindows.values) { controller.close() }
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
            automaticSwitchSessionOptions = automaticSwitchOptions.read()
            beginAutomaticSwitch(invocation)
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
        if existing, localMouse == nil, let invocation = currentInvocation { observeSession(invocation) }
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
        if capture.state.phase == .saving {
            _ = capture.handle(.dismissed)
            record("capture.dismiss-deferred", extra: ["reason": reason.rawValue])
            // Release keyboard control on Escape, but retain the visible save
            // and its text. No callback may later restore the old destination.
            removeSessionObservers()
            origin = nil
            originWindow = nil
            originResponder = nil
            if reason == .escape { panel.resignKey() }
            return
        }
        record("dismiss.\(reason.rawValue)")
        endAutomaticSwitch(reason == .saved || capture.state.phase == .saved ? .saved : .dismissed)
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
    func open(_ destination: WorkingWindow, section: MainSection? = nil, from invocation: Invocation? = nil) -> Bool {
        if let invocation, currentInvocation != invocation {
            record("destination.stale-ignored")
            return false
        }
        if let currentInvocation { dismiss(currentInvocation, reason: .destination) }
        if workingWindows[destination] == nil {
            let controller = WorkingWindowController(collection: collection)
            controller.window?.delegate = self
            workingWindows[destination] = controller
        }
        updateActivationPolicy()
        guard let controller = workingWindows[destination], let window = controller.window else { return false }
        if let section { controller.presentation.select(section) }
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
        record("working.open", extra: ["destination": "main"])
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
        workingWindows.removeValue(forKey: destination)?.stopObserving()
        if originWindow === window { originWindow = nil; originResponder = nil }
        updateActivationPolicy()
        record("working.closed", extra: ["destination": "main"])
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Clicking a retained failure resumes its ordinary session observers.
        if notification.object as? NSWindow === panel {
            if localMouse == nil, let invocation = currentInvocation { observeSession(invocation) }
        } else {
            record("working.becameKey")
        }
    }

    func windowDidMiniaturize(_ notification: Notification) { record("working.minimized") }
    func windowDidDeminiaturize(_ notification: Notification) { record("working.deminiaturized") }

    @objc private func openMainWindow() { open(.main, from: currentInvocation) }

    private func configurePanel() {
        panel.delegate = self
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
        tint.layer?.backgroundColor = HanaColor.Bezel.tint.cgColor
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

        modeLabel.font = HanaFont.label.nsFont
        modeLabel.textColor = HanaColor.Text.secondary
        modeLabel.sizeToFit()
        modeLabel.frame.origin = NSPoint(x: card.frame.width - labelTrailing - modeLabel.frame.width,
                                         y: 30 - modeLabel.frame.height / 2)
        modeLabel.autoresizingMask = [.minXMargin, .minYMargin]
        modeLabel.isHidden = true
        card.addSubview(modeLabel)

        // Choosing hands typing back to the editor.
        destinationSelector.rootView.choose = { [weak self] index in self?.destinationChosen(index) }
        destinationSelector.frame.size = destinationSelector.fittingSize
        destinationSelector.autoresizingMask = [.minXMargin, .minYMargin]
        destinationSelector.isHidden = true
        card.addSubview(destinationSelector)

        captureNotice.font = HanaFont.label.nsFont
        captureNotice.textColor = HanaColor.Text.secondary
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
        scroll.verticalScroller = NoteScroller()
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        editor.frame = scroll.bounds
        editor.minSize = NSSize(width: 0, height: BarStyle.editorHeight)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.font = HanaFont.Bar.input.nsFont
        editor.textColor = HanaColor.Text.primary
        editor.typingAttributes = BarStyle.textAttributes
        editor.insertionPointColor = HanaColor.Text.primary
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
            self.updateAutomaticSwitchEligibility()
            let effects = self.automaticSwitch?.handle(.reversed(.escape)) ?? []
            if effects.contains(where: { if case .returnToSearch = $0 { true } else { false } }) {
                self.performAutomaticSwitch(effects)
            } else { self.dismiss(invocation, reason: .escape) }
        }
        editor.compositionChanged = { [weak self] in
            self?.updateModeIcon()
            self?.updateAutomaticSwitchBuffer()
        }
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
        let keepGate = automaticSwitch?.lastModeChangeWasAutomatic == true && mode != .search
        if keepGate {
            results = []; icons = [:]; selectedRow = nil
        } else { resetSearch() }
        applyModePresentation(animated: panel.isVisible)
        // Search shows the results for the text it kept; automatic capture keeps a gate-only stream.
        if mode == .search { updateQuery(editor.string) } else { renderResults() }
    }

    private func applyModePresentation(animated: Bool) {
        let capturing = mode != .search
        let name = mode == .task ? "Task" : "Note"
        editor.placeholder = capturing ? nil : "Search"
        editor.setAccessibilityLabel(capturing ? name : "Search")
        editor.setAccessibilityPlaceholderValue(capturing ? nil : "Search")
        modeLabel.isHidden = !capturing
        switch mode {
        // Search's glyph follows its query; clearing the editor restores the logo.
        case .search: updateModeIcon()
        case .note: modeIcon.setGlyph(.note, animated: animated)
        case .task: modeIcon.setGlyph(.task, animated: animated)
        }
        // Only Note is a multiline surface.
        editorScroll.hasVerticalScroller = mode == .note
        setModeLabel(name)
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
        addOpenMainWindow(to: menu, shortcut: false)
        menu.addItem(.separator())
        addAutomaticSwitchMenu(to: menu)
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
        addOpenMainWindow(to: windows, shortcut: true)
        windows.addItem(.separator())
        windows.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windows.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windows
        main.addItem(windowItem)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }

    private func addAutomaticSwitchMenu(to menu: NSMenu) {
        let title = "Automatic switch (prototype)"
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        submenu.delegate = self
        automaticSwitchMenu = submenu
        root.submenu = submenu
        menu.addItem(root)
        let toggle = NSMenuItem(title: "On", action: #selector(toggleAutomaticSwitch), keyEquivalent: "")
        toggle.target = self
        automaticSwitchToggle = toggle
        submenu.addItem(toggle)
        addAutomaticSwitchBehaviorMenus(to: submenu)
        if let classifierServices {
            classifierMenuController = ClassifierMenuController(menu: submenu, services: classifierServices, options: automaticSwitchOptions)
        } else { submenu.item(withTitle: "Classifier")?.submenu?.item(withTitle: "Jev")?.isEnabled = false }
        submenu.addItem(.separator())
        automaticSwitchCountItems = (0..<4).map { _ in
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.isEnabled = false
            submenu.addItem(item)
            return item
        }
        submenu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset Counts", action: #selector(resetAutomaticSwitchCounts), keyEquivalent: "")
        reset.target = self
        automaticSwitchReset = reset
        submenu.addItem(reset)
        let reveal = NSMenuItem(title: "Reveal Log", action: #selector(revealAutomaticSwitchLog), keyEquivalent: "")
        reveal.target = self
        submenu.addItem(reveal)
        refreshAutomaticSwitchMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === automaticSwitchMenu { refreshAutomaticSwitchMenu() }
    }

    private func refreshAutomaticSwitchMenu() {
        classifierMenuController?.refresh()
        let options = automaticSwitchOptions.read()
        automaticSwitchToggle?.state = options.isEnabled ? .on : .off
        for (item, matches) in automaticSwitchChoices { item.state = matches(options) ? .on : .off }
        automaticSwitchReset?.isEnabled = options.isEnabled
        let counts = automaticSwitchDiagnostics.counts()
        let titles = [
            "Switches \(counts.switches) · Wrong \(counts.wrongSwitches) · Ambiguous \(counts.ambiguous)",
            "Reversals \(counts.reversals) · Missed \(counts.missed) · Errors \(counts.errors) · Timeouts \(counts.timeouts)"
        ] + AutomaticSwitchOptions.Classifier.allCases.map { classifier in
            let name = classifier == .foundationModels ? "Foundation Models" : "Jev"
            guard let latency = counts.latencies[classifier] else { return "\(name): median 0 ms · max 0 ms" }
            return "\(name): median \(latency.medianMilliseconds.formatted(.number.precision(.fractionLength(0)))) ms · max \(latency.maximumMilliseconds.formatted(.number.precision(.fractionLength(0)))) ms"
        }
        for (item, title) in zip(automaticSwitchCountItems, titles) { item.title = title }
    }

    private func addAutomaticSwitchBehaviorMenus(to menu: NSMenu) {
        automaticSwitchChoices = []; automaticSwitchMutations = []
        addOptionMenu("Classifier", to: menu, keyPath: \.classifier,
            choices: [(.foundationModels, "Foundation Models"), (.jev, "Jev")])
        addOptionMenu("Fires", to: menu, keyPath: \.firing,
            choices: [(.everyKeystroke, "Every keystroke"), (.debounced, "Debounced (150 ms)"), (.onPause, "On pause (500 ms)")])
        addOptionMenu("Jev threshold", to: menu, keyPath: \.jevThreshold,
            choices: AutomaticSwitchOptions.Threshold.allCases.map { ($0, String(format: "%.2f", $0.rawValue)) })
        addOptionMenu("Foundation Models unsure", to: menu, keyPath: \.foundationModelsUnsure,
            choices: [(true, "On"), (false, "Off")])
        addOptionMenu("Agreeing verdicts needed", to: menu, keyPath: \.agreeingVerdicts, choices: [(.one, "1"), (.two, "2")])
        addOptionMenu("After a switch", to: menu, keyPath: \.afterSwitch,
            choices: [(.stay, "Stay in that mode"), (.keepClassifying, "Keep classifying")])
        addOptionMenu("Navigating results stops switching", to: menu, keyPath: \.navigationSuspends,
            choices: [(true, "On"), (false, "Off")])
        addOptionMenu("Enter just after a switch", to: menu, keyPath: \.enterBehavior,
            choices: [(.saves, "Saves"), (.ignoreFor300Milliseconds, "Ignored for 300 ms")])
        addOptionMenu("Escape right after a switch", to: menu, keyPath: \.escapeBehavior,
            choices: [(.returnsToSearch, "Returns to Search"), (.dismisses, "Dismisses")])
        addOptionMenu("Reversing stops switching", to: menu, keyPath: \.reversalSuspends,
            choices: [(true, "On"), (false, "Off")])
        addOptionMenu("Wait before switching", to: menu, keyPath: \.wait,
            choices: [(.allSources, "For all Search sources"), (.appsAndCollection, "For apps and collection only"), (.none, "Don't wait")])
        addOptionMenu("Strong match lands after a switch", to: menu, keyPath: \.lateStrongMatch,
            choices: [(.returnToSearch, "Return to Search"), (.stay, "Stay")])
    }

    private func addOptionMenu<Value: Equatable>(_ title: String, to menu: NSMenu,
        keyPath: WritableKeyPath<AutomaticSwitchOptions, Value>, choices: [(Value, String)]) {
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title); submenu.autoenablesItems = false
        for (value, label) in choices {
            let item = NSMenuItem(title: label, action: #selector(selectAutomaticSwitchOption(_:)), keyEquivalent: "")
            item.target = self; item.tag = automaticSwitchMutations.count
            automaticSwitchMutations.append { $0[keyPath: keyPath] = value }
            automaticSwitchChoices.append((item, { $0[keyPath: keyPath] == value }))
            submenu.addItem(item)
        }
        root.submenu = submenu; menu.addItem(root)
    }

    @objc private func selectAutomaticSwitchOption(_ sender: NSMenuItem) {
        guard automaticSwitchMutations.indices.contains(sender.tag) else { return }
        var options = automaticSwitchOptions.read()
        automaticSwitchMutations[sender.tag](&options)
        automaticSwitchOptions.write(options)
        refreshAutomaticSwitchMenu()
    }

    @objc private func toggleAutomaticSwitch() {
        var options = automaticSwitchOptions.read()
        options.isEnabled.toggle()
        automaticSwitchOptions.write(options)
        refreshAutomaticSwitchMenu()
    }

    @objc private func resetAutomaticSwitchCounts() {
        automaticSwitchDiagnostics.resetCounts(options: automaticSwitchOptions.read())
        refreshAutomaticSwitchMenu()
    }

    @objc private func revealAutomaticSwitchLog() {
        let url = automaticSwitchDiagnostics.url
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    private func addOpenMainWindow(to menu: NSMenu, shortcut: Bool) {
        let item = NSMenuItem(title: "Open Hana", action: #selector(openMainWindow),
                              keyEquivalent: shortcut ? "1" : "")
        item.target = self
        menu.addItem(item)
    }

    private func beginAutomaticSwitch(_ invocation: Invocation) {
        let epoch = ContinuousClock.now
        automaticSwitch = AutomaticSwitch(options: automaticSwitchSessionOptions,
            now: { epoch.duration(to: ContinuousClock.now) })
        performAutomaticSwitch(automaticSwitch?.handle(.invoked) ?? [])
        guard automaticSwitchSessionOptions.isEnabled else { return }
        classifier = classifierFactory?(automaticSwitchSessionOptions)
        classifier?.prewarm()
        gateTitles = StrongMatchGate.Titles(status: collection == nil ? .unavailable : .loading)
        let collection = collection
        titleObservation = Task { [weak self] in
            let store = try? await collection?.value
            guard let self, self.currentInvocation == invocation, !Task.isCancelled else { return }
            let source = CollectionTitleSource(store: store)
            self.titleSource = source
            for await titles in source.snapshots() {
                guard self.currentInvocation == invocation, !Task.isCancelled else { return }
                self.gateTitles = titles
                self.refreshAutomaticSwitchGate()
            }
        }
        automaticSwitchTicker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                guard let self, self.currentInvocation == invocation else { return }
                self.performAutomaticSwitch(self.automaticSwitch?.handle(.tick) ?? [])
            }
        }
    }

    private func endAutomaticSwitch(_ end: AutomaticSwitchDiagnostics.End) {
        performAutomaticSwitch(automaticSwitch?.handle(.dismissed(end)) ?? [])
        automaticSwitchTicker?.cancel(); automaticSwitchTicker = nil
        titleObservation?.cancel(); titleObservation = nil; titleSource = nil
        classificationTasks.values.forEach { $0.cancel() }; classificationTasks = [:]
        classifier = nil; automaticSwitch = nil; gateResults = []
    }

    private func automaticSwitchGate() -> StrongMatchGate.Evaluation {
        StrongMatchGate.evaluate(rawBuffer: editor.string, results: gateResults,
            appStatus: sourceStatus, fileStatus: fileStatus, titles: gateTitles)
    }

    private func updateAutomaticSwitchBuffer() {
        guard currentInvocation != nil else { return }
        updateAutomaticSwitchEligibility()
        performAutomaticSwitch(automaticSwitch?.handle(.bufferChanged(text: editor.string,
            composing: editor.hasMarkedText(), gate: automaticSwitchGate())) ?? [])
    }

    private func refreshAutomaticSwitchGate() {
        guard currentInvocation != nil else { return }
        updateAutomaticSwitchEligibility()
        performAutomaticSwitch(automaticSwitch?.handle(.gateChanged(automaticSwitchGate())) ?? [])
    }

    private func updateAutomaticSwitchEligibility() {
        let eligible = heldEnter == nil && pendingLaunch == nil && capture.state.phase == .editing
        performAutomaticSwitch(automaticSwitch?.handle(.eligibilityChanged(eligible)) ?? [])
    }

    private func performAutomaticSwitch(_ effects: [AutomaticSwitch.Effect]) {
        for effect in effects {
            switch effect {
            case .record(let event):
                automaticSwitchDiagnostics.record(event, options: automaticSwitchSessionOptions)
            case .cancel(let id):
                classificationTasks.removeValue(forKey: id)?.cancel()
            case .classify(let id, let text):
                guard let invocation = currentInvocation else { continue }
                let classifier = classifier
                classificationTasks[id] = Task { [weak self] in
                    let started = ContinuousClock.now
                    let event: AutomaticSwitch.Event
                    do {
                        guard let classifier else { throw ClassifierFailure(kind: .unavailable) }
                        let verdict = try await classifier.classify(text)
                        let duration = started.duration(to: ContinuousClock.now)
                        let latency = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
                        event = .verdict(id: id, verdict, latencyMilliseconds: latency)
                    } catch {
                        let duration = started.duration(to: ContinuousClock.now)
                        let latency = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
                        event = .failed(id: id, (error as? ClassifierFailure)?.kind ?? .other, latencyMilliseconds: latency)
                    }
                    guard let self, self.currentInvocation == invocation else { return }
                    self.classificationTasks[id] = nil
                    self.updateAutomaticSwitchEligibility()
                    self.performAutomaticSwitch(self.automaticSwitch?.handle(event) ?? [])
                }
            case .enterMode(let mode):
                guard heldEnter == nil, pendingLaunch == nil, !editor.hasMarkedText(),
                      capture.state.phase == .editing else { continue }
                capture.handle(.automaticMode(mode)).forEach(perform)
            case .returnToSearch:
                guard heldEnter == nil, pendingLaunch == nil, !editor.hasMarkedText(),
                      capture.state.phase == .editing else { continue }
                capture.handle(.automaticMode(.search)).forEach(perform)
            case .swallowEnter: break
            }
        }
    }

    /// A click on Task's selector. The session decides; the selector then shows its choice.
    private func destinationChosen(_ index: Int) {
        guard currentInvocation != nil, TaskPlacement.allCases.indices.contains(index) else { return }
        _ = capture.handle(.chooseDestination(TaskPlacement.allCases[index]))
        record("capture.destination", extra: ["destination": capture.state.destination.rawValue])
        renderResults()
        panel.makeFirstResponder(editor)
    }

    func textDidChange(_ notification: Notification) {
        record("editor.changed")
        _ = capture.handle(.edited(text: editor.string, selection: editor.selectedRange()))
        if mode == .search || automaticSwitch?.lastModeChangeWasAutomatic == true {
            updateQuery(editor.string)
        } else { renderResults() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        _ = capture.handle(.edited(text: editor.string, selection: editor.selectedRange()))
    }

    /// The editor asks before applying each native insertion. Returns false when
    /// the session consumed it, so it never becomes text or an undoable edit.
    private func shouldInsert(_ text: String, replacing range: NSRange, provenance: CaptureSession.Provenance) -> Bool {
        guard currentInvocation != nil else { return true }
        let notice = capture.state.notice
        var applies = true
        let previousMode = mode
        let effects = capture.handle(.insert(text, replacing: range, provenance: provenance))
        recordMissedSwitch(previousMode: previousMode, effects: effects)
        for effect in effects {
            switch effect {
            case .consumeInsertion: applies = false
            default: perform(effect)
            }
        }
        // A refused insertion changes no text, so only its explanation needs showing.
        if !applies, capture.state.notice != notice {
            record("capture.refused-multiline", extra: ["mode": mode.rawValue])
            renderResults()
        }
        return applies
    }

    /// Enter in Note or Task. Repeated Enter while saving, and Enter during the
    /// confirmation, do nothing: the session has already frozen the text.
    private func submitCapture() {
        let effects = capture.handle(.submit)
        updateAutomaticSwitchEligibility()
        if effects.isEmpty, capture.state.notice == .blank { record("capture.refused-blank") }
        effects.forEach(perform)
        renderResults()
    }

    private func perform(_ effect: CaptureSession.Effect) {
        guard let invocation = currentInvocation else { return }
        switch effect {
        case .enterMode(let mode): show(mode)
        case .saveNote(let operation, let body):
            save(.createNote(operation: operation, body: body), operation: operation, from: invocation)
        case .saveTask(let operation, let title, let placement):
            save(.createTask(operation: operation, title: title, placement: placement), operation: operation, from: invocation)
        case .confirmSaved:
            // A task's confirmation says which list it went to.
            setModeLabel(mode == .task ? "Saved to \(capture.state.destination.title)" : "Saved")
            let duration = confirmationDuration
            // Focus returns to the invocation origin when the confirmation ends.
            confirmationTask = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard let self, !Task.isCancelled, self.currentInvocation == invocation else { return }
                self.dismiss(invocation, reason: .saved)
            }
        case .closeSaved:
            dismiss(invocation, reason: .saved)
        // Only `shouldInsert` can drop an insertion.
        case .consumeInsertion: break
        }
    }

    /// Issues the session's one save. Its outcome reaches only the invocation
    /// and operation that requested it.
    private func save<Saved: Sendable>(_ command: CollectionCommand<Saved>, operation: UUID, from invocation: Invocation) {
        record("capture.save-request", extra: ["mode": mode.rawValue])
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
                _ = try await store.perform(command, in: store.generation)
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
        updateAutomaticSwitchEligibility()
        renderResults()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        // The session may take these before the editor acts: Backspace at the
        // start of a capture returns to Search, and in Task, Tab chooses the
        // destination and a line break does nothing.
        let event: CaptureSession.Event? = switch commandSelector {
        case #selector(NSResponder.deleteBackward(_:)): .deleteBackward
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)),
             #selector(NSResponder.insertTabIgnoringFieldEditor(_:)): .tab
        case #selector(NSResponder.insertNewline(_:)) where editor.shiftHeld: .newline
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertParagraphSeparator(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): .newline
        default: nil
        }
        if let event {
            if event == .deleteBackward, mode != .search,
               capture.state.selection == NSRange(location: 0, length: 0), capture.state.phase == .editing {
                let effects = automaticSwitch?.handle(.reversed(.backspace)) ?? []
                if effects.contains(where: { if case .returnToSearch = $0 { true } else { false } }) {
                    performAutomaticSwitch(effects)
                    return true
                }
            }
            let effects = capture.handle(event)
            if !effects.isEmpty {
                if event == .deleteBackward {
                    performAutomaticSwitch(automaticSwitch?.handle(.manualModeChanged(.search)) ?? [])
                }
                if event == .tab { record("capture.destination", extra: ["destination": capture.state.destination.rawValue]) }
                effects.forEach(perform)
                renderResults()
                return true
            }
            // Ordinary deletion, tab or line break.
            if event == .deleteBackward || mode != .search { return false }
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), !editor.shiftHeld {
            let effects = automaticSwitch?.handle(.enter) ?? []
            if effects.contains(where: { if case .swallowEnter = $0 { true } else { false } }) { return true }
        }
        if mode != .search {
            // Plain Enter saves.
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
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
        // Automatic capture uses Search only as a gate, never as visible rows.
        guard mode == .search || automaticSwitch?.lastModeChangeWasAutomatic == true else { return renderResults() }
        updateModeIcon()
        searchTask?.cancel()
        // A new query owns a new open intent; an old acknowledgment cannot
        // block Enter or report an error into this context.
        pendingLaunch = nil
        heldEnter = nil
        let request = Search.Request(text: CaptureSession.searchQuery(for: text))
        self.request = request
        userMovedSelection = false
        openFailure = nil
        let stream = search.search(request)
        gateResults = stream.initial.results
        currentMatchIDs = Set(stream.initial.results.map(\.id))
        // Keep the displayed snapshot intact until a source delivers its
        // replacement. An edit alone must not remove nonmatching rows.
        if mode == .search, results.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = stream.initial.results
            displayedResultsGeneration = request.generation
        }
        selectedRow = rows.first?.id
        icons = icons.filter { id, _ in results.contains { $0.id == id } }
        sourceStatus = stream.initial.appStatus
        fileStatus = stream.initial.fileStatus
        updateAutomaticSwitchBuffer()
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
                self.gateResults = batch.results
                self.currentMatchIDs.formUnion(batch.results.map(\.id))
                // Empty or cache-only intermediate batches are not a
                // replacement: a source has yet to deliver fresh matches.
                if self.mode == .search, batch.hasFreshResults || (batch.appStatus != .loading && batch.fileStatus != .loading) {
                    self.results = batch.results
                    self.displayedResultsGeneration = batch.generation
                    self.icons = self.icons.filter { id, _ in batch.results.contains { $0.id == id } }
                    if !self.userMovedSelection || !self.rows.contains(where: { $0.id == self.selectedRow }) {
                        self.selectedRow = self.rows.first?.id
                        self.userMovedSelection = false
                    }
                }
                self.renderResults()
                if self.heldEnter != nil { self.releaseHeldEnter() }
                self.refreshAutomaticSwitchGate()
                self.record("search.batch", extra: ["resultCount": batch.results.count, "appStatus": batch.appStatus.rawValue, "fileStatus": batch.fileStatus.rawValue,
                    "applicationCount": batch.results.filter { $0.kind == .application }.count,
                    "fileCount": batch.results.filter { $0.kind != .application }.count,
                    "elapsedMilliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000])
            }
        }
    }

    func moveSelection(by offset: Int) {
        let rows = rows
        guard !rows.isEmpty else { return }
        let index = selectedRow.flatMap { id in rows.firstIndex { $0.id == id } }
        let next = index.map { min(rows.count - 1, max(0, $0 + offset)) } ?? (offset < 0 ? rows.count - 1 : 0)
        selectedRow = rows[next].id
        userMovedSelection = true
        performAutomaticSwitch(automaticSwitch?.handle(.navigated) ?? [])
        renderResults()
        record("search.selection", extra: ["index": next])
    }

    /// Enter in Search: opens the selected result or chooses the selected
    /// suggestion; unmatched text is never saved from Search. Returns nil when
    /// nothing was opened now, including when Enter is held because the
    /// selected row does not match the current request.
    @discardableResult
    func requestSelectedOpen() -> Task<Void, Never>? {
        guard currentInvocation != nil, pendingLaunch == nil else { return nil }
        if case .suggestion(let suggestion) = selectedRow {
            // Unnavigated, it is the top row only for now: a strong late match must not be skipped.
            if !userMovedSelection, sourceStatus == .loading || fileStatus == .loading {
                hold(.suggestion, destinationKind: "Suggestion")
            } else {
                heldEnter = nil
                choose(suggestion)
            }
            return nil
        }
        guard let invocation = currentInvocation, let destination = selectedResult else { return nil }
        // Enter again after navigating to a matching row opens it at once.
        guard currentMatchIDs.contains(destination.id) else {
            hold(.result, destinationKind: destination.typeLabel)
            return nil
        }
        heldEnter = nil
        return openResult(destination, from: invocation)
    }

    private func hold(_ held: HeldEnter, destinationKind: String) {
        heldEnter = held
        updateAutomaticSwitchEligibility()
        openFailure = nil
        renderResults()
        record("launch.held", extra: ["destinationKind": destinationKind])
    }

    /// Switches to the suggestion's mode keeping the text, or explains why
    /// multiline text can't become a task. Never saves.
    private func choose(_ suggestion: CaptureSession.Suggestion) {
        record("search.suggestion", extra: ["mode": suggestion.mode.rawValue])
        let previousMode = mode
        let effects = capture.handle(.chooseSuggestion(suggestion))
        recordMissedSwitch(previousMode: previousMode, effects: effects)
        if effects.isEmpty, capture.state.notice == .multilineTask {
            record("capture.refused-multiline", extra: ["mode": mode.rawValue])
            renderResults()
        }
        effects.forEach(perform)
    }

    private func recordMissedSwitch(previousMode: CaptureSession.Mode, effects: [CaptureSession.Effect]) {
        guard previousMode == .search else { return }
        for effect in effects {
            guard case .enterMode(let mode) = effect, mode != .search,
                  let recordedMode = AutomaticSwitchDiagnostics.Mode(rawValue: mode.rawValue) else { continue }
            if Note.isNonblank(capture.state.text), automaticSwitch?.hasActedOnCurrentBuffer != true {
                automaticSwitchDiagnostics.record(.missed(mode: recordedMode, lastVerdict: automaticSwitch?.lastVerdict ?? .none),
                                                  options: automaticSwitchSessionOptions)
            }
            performAutomaticSwitch(automaticSwitch?.handle(.manualModeChanged(mode)) ?? [])
        }
    }

    /// Opens the row selected under the usual rules once it matches the
    /// current request. Once both sources finish without one, Enter on a
    /// suggestion chooses the suggestion then selected; any other hold ends.
    private func releaseHeldEnter() {
        guard let invocation = currentInvocation, let held = heldEnter else { return }
        if let destination = selectedResult, currentMatchIDs.contains(destination.id) {
            heldEnter = nil
            openResult(destination, from: invocation)
        } else if sourceStatus != .loading && fileStatus != .loading {
            heldEnter = nil
            if held == .suggestion, case .suggestion(let suggestion) = selectedRow {
                choose(suggestion)
            } else {
                renderResults()
                record("launch.held-cancelled")
            }
        }
    }

    @discardableResult
    private func openResult(_ destination: SearchResult, from invocation: Invocation) -> Task<Void, Never> {
        let operation = UUID()
        pendingLaunch = operation
        updateAutomaticSwitchEligibility()
        let generation = request?.generation
        openFailure = nil
        renderResults()
        record("launch.request", extra: ["destinationKind": destination.typeLabel])
        return Task {
            guard currentInvocation == invocation, pendingLaunch == operation else { return }
            let validated: ValidatedDestination
            do {
                validated = try await (destination.kind == .application ? launchApplication(destination.url) : openFile(destination.url))
            } catch {
                guard currentInvocation == invocation, pendingLaunch == operation else { return }
                pendingLaunch = nil
                updateAutomaticSwitchEligibility()
                if request?.generation == generation {
                    openFailure = Self.openFailureMessage(error)
                }
                renderResults()
                // Numeric classification only; localized errors may expose paths.
                let failure = error as NSError
                record("launch.failed", extra: ["errorDomain": failure.domain, "errorCode": failure.code])
                return
            }
            guard currentInvocation == invocation, pendingLaunch == operation else {
                record("launch.stale-validation")
                return
            }
            pendingLaunch = nil
            guard request?.generation == generation else { renderResults(); return }
            // Close before the native open: a slow-launching app must not hold
            // the bar. Its failures can no longer show here, so they only beep.
            dismiss(invocation, reason: .destination)
            let frontmost = frontmostApplication()?.processIdentifier
            do {
                let activate = try await validated.open()
                search.recordOpened(destination.id)
                record("launch.acknowledged")
                // The workspace open requested no activation. Never activate it
                // over a later user choice: a newer bar or another app in front.
                guard currentInvocation == nil, frontmostApplication()?.processIdentifier == frontmost else {
                    record("launch.activation-skipped")
                    return
                }
                let accepted = activate()
                record("launch.activation-request", extra: ["accepted": accepted])
            } catch {
                NSSound.beep()
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

    private static func launch(_ url: URL) async throws -> ValidatedDestination {
        guard FileManager.default.fileExists(atPath: url.path),
              let bundle = Bundle(url: url), let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return ValidatedDestination {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.allowsRunningApplicationSubstitution = false
            configuration.promptsUserIfNeeded = false
            let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return { requestActivation(application) }
        }
    }

    private static func openFileDestination(_ url: URL) async throws -> ValidatedDestination {
        // Revalidate off the input actor: a disconnected volume must not block typing.
        try await Task.detached(priority: .userInitiated) {
            guard Search.eligible(url) else { throw CocoaError(.fileReadUnknown) }
            // Keep filesystem errors intact. Boolean existence/readability checks
            // erase the distinction between missing resources and access denial.
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        }.value
        return ValidatedDestination {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.promptsUserIfNeeded = false
            let application = try await NSWorkspace.shared.open(url, configuration: configuration)
            return { requestActivation(application) }
        }
    }

    private static func requestActivation(_ application: NSRunningApplication) -> Bool {
        guard let source = NSWorkspace.shared.frontmostApplication else { return application.activate(options: []) }
        return application.activate(from: source, options: [])
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
        heldEnter = nil
        results = []
        displayedResultsGeneration = nil
        icons = [:]
        selectedRow = nil
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
        guard mode == .search else { return layoutCapture() }
        // A capture's notices show below its text. Search shows only a refused
        // switch to Task, as its status; returning leaves the others behind.
        captureNotice.isHidden = true
        let notice = capture.state.notice.map { Self.noticeMessage($0, mode: mode) }
        let loading = hasQuery && (sourceStatus == .loading || fileStatus == .loading)
        loadingIndicator.isHidden = !loading
        if loading { loadingIndicator.startAnimation(nil) } else { loadingIndicator.stopAnimation(nil) }
        let status: String?
        if !hasQuery { status = notice }
        else if let openFailure { status = openFailure }
        else if pendingLaunch != nil || heldEnter != nil { status = "Opening selected destination…" }
        else if let notice { status = notice }
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
        let needed = hasQuery || notice != nil ? SearchResultsView.height(rowCount: rows.count, hasStatus: status != nil) : 0
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
        resultSurface?.rootView = SearchResultsView(rows: rows, query: CaptureSession.searchQuery(for: query),
            selectedID: selectedRow, status: status, icons: icons,
            scrollResetID: request?.generation, followsFirstResult: !userMovedSelection,
            scrollOffsetChanged: { [weak self] in self?.resultsScrollOffset = $0 },
            select: { [weak self] id in
                guard let self, self.rows.contains(where: { $0.id == id }) else { return }
                self.selectedRow = id
                self.userMovedSelection = true
                self.renderResults()
                self.panel.makeFirstResponder(self.editor)
            }, rowAppeared: { [weak self] id in self?.requestIcon(id) })
    }

    /// Note grows with its text to a maximum height and then scrolls; Task stays
    /// one line unless its title soft-wraps. Like the results, a capture extends
    /// the card downward so the input never moves; placement shifts the bar only
    /// to keep it on screen.
    private func layoutCapture() {
        loadingIndicator.isHidden = true
        loadingIndicator.stopAnimation(nil)
        resultSurface?.isHidden = true
        retainedContentHeight = 0
        // Submitted text and destination are frozen until a failure returns them for editing.
        editor.isEditable = capture.state.phase == .editing
        destinationSelector.rootView.isEnabled = capture.state.phase == .editing
        switch capture.state.phase {
        case .saving: setModeLabel("Saving…")
        case .editing: setModeLabel(mode == .task ? "Task" : "Note")
        case .saved: break
        }
        if let index = TaskPlacement.allCases.firstIndex(of: capture.state.destination) {
            destinationSelector.rootView.selection = index
        }
        let notice = capture.state.notice.map { Self.noticeMessage($0, mode: mode) }
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

    /// Search shows only the refused switch to Task; the rest belong to the capture mode.
    private static func noticeMessage(_ notice: CaptureSession.Notice, mode: CaptureSession.Mode) -> String {
        let kind = mode == .task ? "task" : "note"
        return switch notice {
        case .blank: "Write something to save this \(kind)."
        case .collectionUnavailable: "The collection couldn’t be opened, so \(kind)s can’t be saved right now. Your text is kept."
        case .failed: "Save not confirmed. Your text is kept. Press Enter to retry."
        case .multilineTask: mode == .task
            ? "Tasks are one line, so text with line breaks can’t be pasted here."
            : "Tasks are one line. Remove the line breaks to make this a task."
        }
    }

    /// The label ends where the results' type labels end, with Task's selector
    /// before it. A capture's text stops short of both; Search's leaves room for
    /// the spinner. The height follows the text; layout sets it.
    private func setModeLabel(_ text: String) {
        guard let card = modeLabel.superview else { return }
        modeLabel.stringValue = text
        modeLabel.sizeToFit()
        let labelTrailing = BarStyle.cardPadding + BarStyle.resultIconInset
        let midY = card.bounds.height - BarStyle.inputHeight + 30
        modeLabel.frame.origin = NSPoint(x: card.bounds.width - labelTrailing - modeLabel.frame.width,
                                         y: midY - modeLabel.frame.height / 2)
        // The confirmation names the destination, so the selector steps aside.
        destinationSelector.isHidden = mode != .task || capture.state.phase == .saved
        destinationSelector.frame.origin = NSPoint(x: modeLabel.frame.minX - 8 - destinationSelector.frame.width,
                                                   y: midY - destinationSelector.frame.height / 2)
        let trailing = mode == .search ? card.bounds.width - 44
            : (destinationSelector.isHidden ? modeLabel.frame.minX : destinationSelector.frame.minX) - 8
        editorScroll.frame = NSRect(x: BarStyle.textInset, y: editorScroll.frame.minY,
                                    width: trailing - BarStyle.textInset, height: editorScroll.frame.height)
    }

    /// The editor's frame lags behind its text, so measure TextKit 2's laid-out
    /// lines. A native editing test fails if the editor falls back to TextKit 1;
    /// asking for its TextKit 1 layout manager here would switch it over.
    private var textHeight: CGFloat {
        guard let layout = editor.textLayoutManager else { return editor.frame.height }
        layout.ensureLayout(for: layout.documentRange)
        return layout.usageBoundsForTextContainer.height + 2 * editor.textContainerInset.height
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
            "working": workingWindows.values.compactMap { controller -> [String: Any]? in
                guard let window = controller.window else { return nil }
                return ["id": "main", "minimized": window.isMiniaturized,
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
           event.charactersIgnoringModifiers == "1" {
            openDestination?(.main)
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
        didSet { updatePlaceholder() }
    }
    /// The placeholder while it is showing.
    var visiblePlaceholder: String? { placeholderView.isHidden ? nil : placeholder }
    /// Behind TextKit 2's insertion indicator, which is also a subview.
    private lazy var placeholderView: PlaceholderView = {
        let view = PlaceholderView()
        view.isHidden = true
        addSubview(view, positioned: .below, relativeTo: nil)
        return view
    }()
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

    // NSTextView has no public placeholder, and overriding `draw(_:)` to paint
    // one makes AppKit fall back to TextKit 1, so a separate view shows it.
    // Composition always hides it, whether or not its marked text is in `string` yet.
    private func updatePlaceholder() {
        placeholderView.text = placeholder.map { NSAttributedString(string: $0, attributes: BarStyle.placeholderAttributes) }
        placeholderView.frame = NSRect(origin: textContainerOrigin, size: placeholderView.text?.size() ?? .zero)
        placeholderView.isHidden = placeholder == nil || !string.isEmpty || hasMarkedText()
    }

    override var string: String {
        didSet { updatePlaceholder() }
    }

    override func invalidateTextContainerOrigin() {
        super.invalidateTextContainerOrigin()
        updatePlaceholder()
    }

    override func didChangeText() {
        super.didChangeText()
        updatePlaceholder()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        performing(.composition) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        }
        updatePlaceholder()
        compositionChanged?()
    }

    override func unmarkText() {
        super.unmarkText()
        updatePlaceholder()
        compositionChanged?()
    }
}

/// Draws the editor's placeholder where its text begins. It never takes a
/// click, so the editor beneath it keeps every mouse interaction.
@MainActor
private final class PlaceholderView: NSView {
    var text: NSAttributedString? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        text?.draw(at: .zero)
    }
}

private extension TaskPlacement {
    /// The list's name in the bar.
    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        }
    }
}
