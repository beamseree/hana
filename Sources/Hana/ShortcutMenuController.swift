import AppKit
import Carbon

enum SearchShortcut: String, CaseIterable {
    case optionSpace
    case commandSpace

    var title: String {
        switch self {
        case .optionSpace: "Option+Space"
        case .commandSpace: "Command+Space"
        }
    }

    var menuTitle: String {
        switch self {
        case .optionSpace: "⌥Space"
        case .commandSpace: "⌘Space"
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .commandSpace: UInt32(cmdKey)
        }
    }

    var hotKeyID: UInt32 {
        switch self {
        case .optionSpace: 1
        case .commandSpace: 2
        }
    }
}

/// Menu actions persist only successfully registered choices. A failed change
/// leaves the previous shortcut available and checked, with Search as fallback.
@MainActor
final class ShortcutMenuController: NSObject {
    static let preferenceKey = "search.shortcut.v1"
    let menu = NSMenu(title: "Search Shortcut")
    let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private(set) var selection: SearchShortcut
    private let defaults: UserDefaults
    private let register: (SearchShortcut) -> OSStatus
    private let statusChanged: (SearchShortcut, OSStatus) -> Void
    private var registrationStatus: OSStatus = OSStatus(eventNotHandledErr)

    init(defaults: UserDefaults = .standard,
         register: @escaping (SearchShortcut) -> OSStatus,
         statusChanged: @escaping (SearchShortcut, OSStatus) -> Void = { _, _ in }) {
        self.defaults = defaults
        self.register = register
        self.statusChanged = statusChanged
        selection = defaults.string(forKey: Self.preferenceKey).flatMap(SearchShortcut.init(rawValue:)) ?? .optionSpace
        super.init()
        menu.autoenablesItems = false
        for (index, shortcut) in SearchShortcut.allCases.enumerated() {
            let item = NSMenuItem(title: shortcut.menuTitle, action: #selector(choose(_:)), keyEquivalent: "")
            item.tag = index
            item.target = self
            menu.addItem(item)
        }
        statusItem.isEnabled = false
        statusItem.title = "Registering \(selection.title)…"
        refreshChecks()
    }

    @discardableResult
    func activate() -> OSStatus {
        registrationStatus = register(selection)
        statusItem.title = registrationStatus == noErr
            ? "\(selection.title) is available"
            : "\(selection.title) unavailable (\(registrationStatus)) — use Search"
        statusChanged(selection, registrationStatus)
        return registrationStatus
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard SearchShortcut.allCases.indices.contains(sender.tag) else { return }
        let requested = SearchShortcut.allCases[sender.tag]
        guard requested != selection || registrationStatus != noErr else { return }
        let result = register(requested)
        if result == noErr {
            selection = requested
            registrationStatus = result
            defaults.set(requested.rawValue, forKey: Self.preferenceKey)
            statusItem.title = "\(selection.title) is available"
            refreshChecks()
        } else {
            let fallback = registrationStatus == noErr ? "still using \(selection.title)" : "use Search"
            statusItem.title = "\(requested.title) unavailable (\(result)) — \(fallback)"
        }
        statusChanged(selection, registrationStatus)
    }

    private func refreshChecks() {
        for (index, shortcut) in SearchShortcut.allCases.enumerated() {
            menu.item(at: index)?.state = shortcut == selection ? .on : .off
        }
    }
}
