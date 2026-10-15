import AppKit

/// Constructed explicitly by normal HanaApp launch, never by MacInteraction's test defaults.
@MainActor
final class ClassifierServices {
    let keychain: JevKeychainStore
    let jevLaunchMemory: JevLaunchMemory
    private var jevKey: String?
    let availability: () -> FoundationModelAvailability
    init(keychain: JevKeychainStore = JevKeychainStore(),
         jevLaunchMemory: JevLaunchMemory = JevLaunchMemory(),
         availability: @escaping () -> FoundationModelAvailability = FoundationModelAvailability.live) {
        self.keychain = keychain
        self.jevLaunchMemory = jevLaunchMemory
        jevKey = try? keychain.read()
        self.availability = availability
    }
    var hasJevKey: Bool { (try? keychain.containsKey()) == true }
    func saveJevKey(_ key: String) throws {
        try keychain.save(key)
        jevKey = nil
        jevKey = try keychain.read()
        jevLaunchMemory.keySaved()
    }
    func removeJevKey() throws {
        try keychain.remove()
        jevKey = nil
        jevKey = try keychain.read()
    }
    func makeClassifier(options: AutomaticSwitchOptions) -> (any Classifier)? {
        switch options.classifier {
        case .foundationModels: FoundationModelsClassifier(unsure: options.foundationModelsUnsure, availability: availability)
        case .jev:
            if jevKey?.isEmpty == false {
                if options.firing == .wordPaced {
                    JevClassifier(keyProvider: { self.jevKey }, transport: { try await JevSharedTransport.live.perform($0) })
                } else { JevClassifier(keyProvider: { self.jevKey }) }
            } else { nil }
        }
    }
}

/// Owns only the key alert and deliberately started fixture check. It opens no working window.
@MainActor
final class ClassifierMenuController: NSObject {
    static let notice = "With Jev selected, Search text goes to TypeSafe in the US with no fixed retention period."
    private let services: ClassifierServices
    private let options: AutomaticSwitchOptionsStore
    private let availabilityItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let keyStatus = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let removeItem = NSMenuItem(title: "Remove Jev API Key", action: nil, keyEquivalent: "")
    private let checkItem = NSMenuItem(title: "Run Tricky-Input Check", action: nil, keyEquivalent: "")
    private weak var jevItem: NSMenuItem?
    private var checkTask: Task<Void, Never>?
    init(menu: NSMenu, services: ClassifierServices, options: AutomaticSwitchOptionsStore) {
        self.services = services; self.options = options
        super.init()
        let classifierMenu = menu.item(withTitle: "Classifier")?.submenu
        jevItem = classifierMenu?.item(withTitle: "Jev")
        availabilityItem.isEnabled = false
        classifierMenu?.insertItem(availabilityItem, at: 1)
        menu.addItem(.separator())
        keyStatus.isEnabled = false; menu.addItem(keyStatus)
        let setItem = NSMenuItem(title: "Set Jev API Key…", action: #selector(setKey), keyEquivalent: "")
        setItem.target = self; menu.addItem(setItem)
        removeItem.target = self; removeItem.action = #selector(removeKey); menu.addItem(removeItem)
        checkItem.target = self; checkItem.action = #selector(runCheck); menu.addItem(checkItem)
        refresh()
    }
    func refresh() {
        let hasKey = services.hasJevKey
        keyStatus.title = services.jevLaunchMemory.keyRejected ? "Jev key rejected" : hasKey ? "Jev API key saved" : "No Jev API key saved"
        jevItem?.isEnabled = hasKey; removeItem.isEnabled = hasKey
        let unavailable = services.availability().menuText
        availabilityItem.title = unavailable ?? ""
        availabilityItem.isHidden = unavailable == nil
        let selected = options.read().classifier
        checkItem.isEnabled = checkTask == nil && (selected == .jev ? hasKey : unavailable == nil)
    }
    @objc private func setKey() {
        let alert = NSAlert()
        alert.messageText = "Set Jev API Key"
        alert.informativeText = Self.notice
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "API key"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        defer { field.stringValue = "" }
        guard response == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do { try services.saveJevKey(key) }
        catch { showFailure("The API key could not be saved to Keychain.") }
        refresh()
    }
    @objc private func removeKey() {
        do { try services.removeJevKey() }
        catch { showFailure("The API key could not be removed from Keychain.") }
        refresh()
    }
    @objc private func runCheck() {
        guard checkTask == nil else { return }
        let snapshot = options.read()
        guard let classifier = services.makeClassifier(options: snapshot) else { return }
        checkItem.title = "Tricky-Input Check Running…"
        checkTask = Task { [weak self] in
            defer { self?.checkTask = nil; self?.checkItem.title = "Run Tricky-Input Check"; self?.refresh() }
            do {
                let report = try await TrickyInputCheck.run(classifier: classifier, options: snapshot)
                let url = try await report.write()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch is CancellationError {} catch { self?.showFailure("The tricky-input report could not be written.") }
        }
        refresh()
    }
    private func showFailure(_ text: String) {
        let alert = NSAlert(); alert.messageText = text; alert.runModal()
    }
}
