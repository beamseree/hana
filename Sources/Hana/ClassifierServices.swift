import AppKit

/// Constructed explicitly by normal HanaApp launch, never by MacInteraction's test defaults.
@MainActor
final class ClassifierServices {
    let keychain: JevKeychainStore
    let availability: () -> FoundationModelAvailability
    init(keychain: JevKeychainStore = JevKeychainStore(),
         availability: @escaping () -> FoundationModelAvailability = FoundationModelAvailability.live) {
        self.keychain = keychain
        self.availability = availability
    }
    var hasJevKey: Bool { (try? keychain.read())?.isEmpty == false }
    func makeClassifier(options: AutomaticSwitchOptions) -> (any Classifier)? {
        switch options.classifier {
        case .foundationModels: FoundationModelsClassifier(unsure: options.foundationModelsUnsure, availability: availability)
        case .jev:
            if let key = try? keychain.read(), !key.isEmpty { JevClassifier(key: key) } else { nil }
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
        keyStatus.title = hasKey ? "Jev API key saved" : "No Jev API key saved"
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
        do { try services.keychain.save(key) }
        catch { showFailure("The API key could not be saved to Keychain.") }
        refresh()
    }
    @objc private func removeKey() {
        do { try services.keychain.remove() }
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
