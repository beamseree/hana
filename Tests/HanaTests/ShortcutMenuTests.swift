import AppKit
import Carbon
import Testing
@testable import Hana

/// Real menu actions, isolated preferences, and scripted registration outcomes.
/// These tests never acquire a system shortcut or show a window.
@MainActor
struct ShortcutMenuTests {
    @Test(arguments: [nil, "unknown-shortcut"] as [String?])
    func missingOrInvalidPreferenceUsesOptionSpace(_ value: String?) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        if let value { fixture.defaults.set(value, forKey: ShortcutMenuController.preferenceKey) }
        var requests: [SearchShortcut] = []
        let controller = ShortcutMenuController(defaults: fixture.defaults, register: {
            requests.append($0)
            return noErr
        })
        #expect(controller.selection == .optionSpace)
        #expect(controller.activate() == noErr)
        #expect(requests == [.optionSpace])
        #expect(controller.menu.item(withTitle: "⌥Space")?.state == .on)
        #expect(controller.menu.item(withTitle: "⌘Space")?.state == .off)
    }

    @Test func switchesBothWaysAndRestoresChoiceOnNextLaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var requests: [SearchShortcut] = []
        let controller = ShortcutMenuController(defaults: fixture.defaults, register: {
            requests.append($0)
            return noErr
        })
        controller.activate()
        controller.menu.performActionForItem(at: controller.menu.indexOfItem(withTitle: "⌘Space"))
        #expect(controller.selection == .commandSpace)
        #expect(controller.menu.item(withTitle: "⌘Space")?.state == .on)
        #expect(controller.menu.item(withTitle: "⌥Space")?.state == .off)
        #expect(controller.statusItem.title == "Command+Space is available")

        let reopenedDefaults = try #require(UserDefaults(suiteName: fixture.name))
        let reopened = ShortcutMenuController(defaults: reopenedDefaults, register: {
            requests.append($0)
            return noErr
        })
        #expect(reopened.selection == .commandSpace)
        reopened.activate()
        reopened.menu.performActionForItem(at: reopened.menu.indexOfItem(withTitle: "⌥Space"))
        #expect(reopened.selection == .optionSpace)
        #expect(reopenedDefaults.string(forKey: ShortcutMenuController.preferenceKey) == "optionSpace")
        #expect(reopened.menu.item(withTitle: "⌥Space")?.state == .on)
        #expect(reopened.menu.item(withTitle: "⌘Space")?.state == .off)
        #expect(requests == [.optionSpace, .commandSpace, .commandSpace, .optionSpace])
    }

    @Test func conflictKeepsWorkingChoiceAndPreference() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("optionSpace", forKey: ShortcutMenuController.preferenceKey)
        var reportedSelection: SearchShortcut?
        var reportedStatus: OSStatus?
        let controller = ShortcutMenuController(defaults: fixture.defaults, register: {
            $0 == .optionSpace ? noErr : OSStatus(eventHotKeyExistsErr)
        }, statusChanged: {
            reportedSelection = $0
            reportedStatus = $1
        })
        controller.activate()
        controller.menu.performActionForItem(at: controller.menu.indexOfItem(withTitle: "⌘Space"))
        #expect(controller.selection == .optionSpace)
        #expect(fixture.defaults.string(forKey: ShortcutMenuController.preferenceKey) == "optionSpace")
        #expect(controller.menu.item(withTitle: "⌥Space")?.state == .on)
        #expect(controller.menu.item(withTitle: "⌘Space")?.state == .off)
        #expect(controller.statusItem.title.contains("Command+Space unavailable"))
        #expect(controller.statusItem.title.contains("still using Option+Space"))
        #expect(reportedSelection == .optionSpace)
        #expect(reportedStatus == noErr)
    }

    @Test func unavailableSavedShortcutCanRecoverUsingOtherChoice() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("commandSpace", forKey: ShortcutMenuController.preferenceKey)
        let controller = ShortcutMenuController(defaults: fixture.defaults, register: {
            $0 == .commandSpace ? OSStatus(eventHotKeyExistsErr) : noErr
        })
        #expect(controller.activate() == OSStatus(eventHotKeyExistsErr))
        #expect(controller.statusItem.title.contains("Command+Space unavailable"))
        #expect(controller.statusItem.title.contains("use Search"))
        controller.menu.performActionForItem(at: controller.menu.indexOfItem(withTitle: "⌘Space"))
        #expect(controller.statusItem.title.contains("use Search"))
        controller.menu.performActionForItem(at: controller.menu.indexOfItem(withTitle: "⌥Space"))
        #expect(controller.selection == .optionSpace)
        #expect(controller.statusItem.title == "Option+Space is available")
        #expect(fixture.defaults.string(forKey: ShortcutMenuController.preferenceKey) == "optionSpace")
    }

    @Test func retriesUnavailableSelectionButDoesNotReregisterWorkingSelection() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var attempts = 0
        let controller = ShortcutMenuController(defaults: fixture.defaults, register: { _ in
            attempts += 1
            return attempts == 1 ? OSStatus(eventHotKeyExistsErr) : noErr
        })
        #expect(controller.activate() == OSStatus(eventHotKeyExistsErr))
        controller.menu.performActionForItem(at: controller.menu.indexOfItem(withTitle: "⌥Space"))
        #expect(controller.statusItem.title == "Option+Space is available")
        controller.menu.performActionForItem(at: controller.menu.indexOfItem(withTitle: "⌥Space"))
        #expect(attempts == 2)
    }

    private struct Fixture {
        let name: String
        let defaults: UserDefaults
        init() throws {
            _ = NSApplication.shared
            name = "com.beamseree.hana.tests.shortcut.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: name))
        }
        func cleanUp() { defaults.removePersistentDomain(forName: name) }
    }
}
