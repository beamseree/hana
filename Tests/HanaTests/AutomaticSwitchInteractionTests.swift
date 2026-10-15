import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct AutomaticSwitchInteractionTests {
    @Test func submenuPersistsToggleAndResetsCountsWithoutOpeningWorkingWindowsOrChangingPolicy() throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.remove() }
        let interaction = MacInteraction(automaticSwitchOptions: fixture.options, automaticSwitchDiagnostics: fixture.log)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        interaction.start()
        defer {
            interaction.stop()
            NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindowsMenu
        }
        let policy = NSApp.activationPolicy()
        let windows = NSApp.windows.filter { $0.isVisible }
        let menu = try #require(interaction.menuBarMenu)
        let submenuIndex = menu.indexOfItem(withTitle: "Automatic switch (prototype)")
        #expect(submenuIndex > menu.indexOfItem(withTitle: "Open Hana"))
        #expect(submenuIndex < menu.indexOfItem(withTitle: "Quit Hana"))
        let submenu = try #require(menu.items[submenuIndex].submenu)
        submenu.delegate?.menuWillOpen?(submenu)
        let toggle = try #require(submenu.item(withTitle: "On"))
        #expect(toggle.state == .off)
        #expect(submenu.item(withTitle: "Switches 0 · Wrong 0 · Ambiguous 0")?.isEnabled == false)
        submenu.performActionForItem(at: submenu.indexOfItem(withTitle: "On"))
        #expect(fixture.options.read().isEnabled && toggle.state == .on)
        fixture.log.record(.switched(mode: .note), options: fixture.options.read())
        submenu.delegate?.menuWillOpen?(submenu)
        #expect(submenu.item(withTitle: "Switches 1 · Wrong 0 · Ambiguous 0") != nil)
        submenu.performActionForItem(at: submenu.indexOfItem(withTitle: "Reset Counts"))
        #expect(fixture.log.counts().switches == 0)
        #expect(NSApp.activationPolicy() == policy)
        #expect(NSApp.windows.filter { $0.isVisible } == windows)
        #expect(interaction.window(for: .main) == nil && interaction.currentInvocation == nil)
    }

    @Test(arguments: [true, false], [CaptureSession.Suggestion.note, .task])
    func prefixAndSuggestionKeepTheirBehaviorAndRecordMissedOnlyWhenEnabled(enabled: Bool, suggestion: CaptureSession.Suggestion) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.remove() }
        var options = fixture.options.read(); options.isEnabled = enabled; fixture.options.write(options)
        let apps = CatalogFeed(), fake = ScriptedClassifier()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            automaticSwitchOptions: fixture.options, automaticSwitchDiagnostics: fixture.log,
            classifierFactory: { _ in fake })
        var invocation = interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        let editor = try await editor()
        editor.insertText("private search บ้าน", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText(suggestion == .note ? "-" : "[", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.mode == suggestion.mode && editor.string == "private search บ้าน")
        #expect(fixture.log.counts().missed == (enabled ? 1 : 0))
        interaction.dismiss(invocation, reason: .outsideClick)
        invocation = interaction.presentBar()
        editor.insertText("another private search", replacementRange: NSRange(location: NSNotFound, length: 0))
        await apps.send([])
        try await eventually { !interaction.isLoading }
        if suggestion == .task { interaction.moveSelection(by: 1) }
        interaction.requestSelectedOpen()
        #expect(interaction.mode == suggestion.mode && editor.string == "another private search")
        #expect(fixture.log.counts().missed == (enabled ? 2 : 0))
        if enabled {
            let data = try String(contentsOf: fixture.log.url, encoding: .utf8)
            #expect(!data.contains("private search"))
        } else {
            #expect(!FileManager.default.fileExists(atPath: fixture.log.url.path))
            #expect(fake.inputs.isEmpty)
        }
    }

    @Test(arguments: [ClassifierVerdict.Label.note, .task], AutomaticSwitchOptions.EnterBehavior.allCases)
    func automaticCaptureKeepsTextAndSelectionAndCommitsExactlyOneItem(label: ClassifierVerdict.Label, enter: AutomaticSwitchOptions.EnterBehavior) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        var options = fixture.options.read(); options.isEnabled = true; options.enterBehavior = enter
        fixture.options.write(options)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            collection: Task { store }, confirmationDuration: .zero, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        let input = "private capture บ้าน"
        editor.insertText(input, replacementRange: NSRange(location: NSNotFound, length: 0))
        let selection = NSRange(location: 2, length: 4); editor.setSelectedRange(selection)
        await apps.send([])
        try await eventually { fake.pendingCount == 1 }
        fake.reply(label)
        try await eventually { interaction.mode != .search }
        #expect(editor.string == input && editor.selectedRange() == selection)
        #expect(!interaction.resultsVisible && interaction.rows.isEmpty)
        if enter == .ignoreFor300Milliseconds {
            editor.keyDown(with: try returnKey())
            #expect(interaction.modeLabelText != "Saving…" && interaction.currentInvocation == invocation)
            let before = try await store.read(.allRecords, in: store.generation)
            #expect(before.notes.isEmpty && before.tasks.isEmpty)
            try await Task.sleep(for: .milliseconds(310))
        }
        editor.keyDown(with: try returnKey())
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.currentInvocation == nil }
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.count + records.tasks.count == 1)
        #expect(records.notes.first?.body == input || records.tasks.first?.title == input)
        #expect(fixture.log.counts().switches == 1 && fixture.log.counts().ambiguous == 0)
        let rows = try String(contentsOf: fixture.log.url, encoding: .utf8)
        #expect(!rows.contains(input) && rows.contains("autoswitch.ended"))
        await store.close()
    }

    @Test(arguments: [AutomaticSwitchDiagnostics.ReversalMethod.escape, .backspace])
    func automaticReversalKeepsTextAndDoesNotCountTheSameManualCaptureAsMissed(method: AutomaticSwitchDiagnostics.ReversalMethod) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        var options = fixture.options.read(); options.isEnabled = true; fixture.options.write(options)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom tomorrow", replacementRange: NSRange(location: NSNotFound, length: 0))
        await apps.send([])
        try await eventually { fake.pendingCount == 1 }; fake.reply(.task)
        try await eventually { interaction.mode == .task }
        if method == .backspace { editor.setSelectedRange(NSRange(location: 0, length: 0)) }
        let selection = editor.selectedRange()
        editor.keyDown(with: try method == .escape ? escapeKey() : backspaceKey())
        #expect(interaction.mode == .search && editor.string == "call mom tomorrow" && editor.selectedRange() == selection)
        #expect(interaction.currentInvocation != nil && fixture.log.counts().wrongSwitches == 1)
        // Choosing a suggestion with the unchanged, previously switched text is not missed.
        try await eventually { apps.subscriptionCount >= 2 }
        await apps.send([]); try await eventually { !interaction.isLoading }
        interaction.requestSelectedOpen()
        #expect(interaction.mode == .note && fixture.log.counts().missed == 0)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.keyDown(with: try backspaceKey())
        try await eventually { apps.subscriptionCount >= 3 }
        // Return-to-Search disarms prefixes: a changed buffer receives a literal dash.
        editor.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.mode == .search && editor.string == "-call mom tomorrow")
        try await eventually { apps.subscriptionCount >= 4 }
        await apps.send([]); try await eventually { !interaction.isLoading }
        interaction.requestSelectedOpen()
        #expect(interaction.mode == .note && fixture.log.counts().missed == 1)
        await store.close()
    }

    @Test func heldEnterCancelsClassificationAndCannotTurnIntoAnAutomaticCapture() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed(), files = CatalogFeed()
        var options = fixture.options.read(); options.isEnabled = true; options.wait = .none
        fixture.options.write(options)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero),
            collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom tomorrow", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { fake.pendingCount == 1 }
        interaction.requestSelectedOpen()
        #expect(interaction.statusMessage == "Opening selected destination…")
        fake.reply(.task)
        try await Task.sleep(for: .milliseconds(50))
        #expect(interaction.mode == .search && fixture.log.counts().switches == 0)
        await apps.send([]); await files.send([])
        try await eventually { interaction.mode == .note }
        #expect(fixture.log.counts().switches == 0)
        await store.close()
    }

    @Test func pendingLaunchCancelsClassificationBeforeItsVerdictCanSwitch() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        var options = fixture.options.read(); options.isEnabled = true; fixture.options.write(options)
        var release: (() -> Void)?
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            launchApplication: { _ in
                await withCheckedContinuation { continuation in release = { continuation.resume() } }
                return .init(activate: { false })
            }, collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom", replacementRange: NSRange(location: NSNotFound, length: 0))
        let weak = SearchResult(name: "My call mom tool", url: URL(fileURLWithPath: "/fixture/Weak.app"))
        await apps.send([weak]); try await eventually { interaction.selectedResult == weak && fake.pendingCount == 1 }
        let opening = interaction.requestSelectedOpen()
        try await eventually { release != nil }
        fake.reply(.task)
        try await Task.sleep(for: .milliseconds(50))
        #expect(interaction.mode == .search && fixture.log.counts().switches == 0)
        release?(); await opening?.value
        await store.close()
    }

    @Test func taskVerdictCannotFlattenPastedMultilineText() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        var options = fixture.options.read(); options.isEnabled = true; fixture.options.write(options)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.string = "a thought\nwith two lines"
        interaction.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        await apps.send([]); try await eventually { fake.pendingCount == 1 }
        fake.reply(.task)
        try await eventually {
            (try? String(contentsOf: fixture.log.url, encoding: .utf8).contains("multiline")) == true
        }
        #expect(interaction.mode == .search && editor.string == "a thought\nwith two lines")
        #expect(fixture.log.counts().switches == 0)
        await store.close()
    }

    @Test func everyBehaviorSubmenuPersistsARadioChoiceForTheNextInvocation() throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let keychain = JevKeychainStore(service: "com.beamsereeyothin.hana.tests.\(UUID().uuidString)")
        try keychain.save("test-only-menu-key")
        defer { try? keychain.remove() }
        let services = ClassifierServices(keychain: keychain, availability: { .available })
        let interaction = MacInteraction(automaticSwitchOptions: fixture.options, automaticSwitchDiagnostics: fixture.log,
            classifierServices: services)
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu
        interaction.start()
        defer { interaction.stop(); NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindows }
        let menu = try #require(interaction.automaticSwitchMenu)
        let groups = menu.items.compactMap(\.submenu)
        #expect(groups.count == 12)
        #expect(groups.allSatisfy { $0.items.filter { $0.state == .on }.count == 1 })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let snapshot = interaction.automaticSwitchSessionOptions
        let policy = NSApp.activationPolicy(), working = interaction.window(for: .main)
        for group in groups {
            group.performActionForItem(at: group.items.count - 1)
            #expect(group.items.last?.state == .on && group.items.filter { $0.state == .on }.count == 1)
        }
        #expect(interaction.automaticSwitchSessionOptions == snapshot)
        let stored = fixture.options.read()
        #expect(stored.classifier == .jev && stored.firing == .pipelinedJev && stored.jevThreshold == .p95)
        #expect(!stored.foundationModelsUnsure && stored.agreeingVerdicts == .two && stored.afterSwitch == .keepClassifying)
        #expect(!stored.navigationSuspends && stored.enterBehavior == .ignoreFor300Milliseconds && stored.escapeBehavior == .dismisses)
        #expect(!stored.reversalSuspends && stored.wait == .none && stored.lateStrongMatch == .stay)
        #expect(NSApp.activationPolicy() == policy && interaction.window(for: .main) === working)
        interaction.dismiss(invocation, reason: .outsideClick)
        _ = interaction.presentBar()
        #expect(interaction.automaticSwitchSessionOptions == stored)
    }

    @Test(arguments: AutomaticSwitchOptions.LateStrongMatch.allCases)
    func lateGateBatchesRemainLiveInCaptureWithoutResurrectingSearchRows(option: AutomaticSwitchOptions.LateStrongMatch) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        var options = fixture.options.read(); options.isEnabled = true; options.wait = .none; options.lateStrongMatch = option
        fixture.options.write(options)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { fake.pendingCount == 1 }; fake.reply(.note)
        try await eventually { interaction.mode == .note }
        let selection = editor.selectedRange()
        await apps.send([SearchResult(name: "Call Mom Helper", url: URL(fileURLWithPath: "/fixture/Call.app"))])
        try await eventually {
            (try? String(contentsOf: fixture.log.url, encoding: .utf8).contains("autoswitch.late-strong-match")) == true
        }
        #expect(editor.string == "call mom" && editor.selectedRange() == selection)
        #expect(interaction.mode == (option == .returnToSearch ? .search : .note))
        #expect(fixture.log.counts().wrongSwitches == (option == .returnToSearch ? 1 : 0))
        if option == .stay { #expect(!interaction.resultsVisible && interaction.rows.isEmpty && interaction.results.isEmpty) }
        await store.close()
    }

    @Test func keepClassifyingMovesCaptureModesAndBackToSearchWithoutEditingTextOrSelection() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        var options = fixture.options.read(); options.isEnabled = true; options.afterSwitch = .keepClassifying
        fixture.options.write(options)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom", replacementRange: NSRange(location: NSNotFound, length: 0))
        await apps.send([]); try await eventually { fake.pendingCount == 1 }; fake.reply(.note)
        try await eventually { interaction.mode == .note }
        for (suffix, label, expected) in [(" tomorrow", ClassifierVerdict.Label.task, CaptureSession.Mode.task),
                                          (" details", .search, .search)] {
            let subscriptions = apps.subscriptionCount
            editor.insertText(suffix, replacementRange: NSRange(location: NSNotFound, length: 0))
            let text = editor.string, selection = editor.selectedRange()
            try await eventually { apps.subscriptionCount > subscriptions }
            await apps.send([]); try await eventually { fake.pendingCount == 1 }
            #expect(interaction.rows.isEmpty && !interaction.resultsVisible)
            fake.reply(label); try await eventually { interaction.mode == expected }
            #expect(editor.string == text && editor.selectedRange() == selection)
        }
        #expect(fixture.log.counts().switches == 3)
        await store.close()
    }

    @Test(arguments: AutomaticSwitchOptions.EscapeBehavior.allCases)
    func escapeAfterAnAutomaticSwitchReversesOnceOrDismissesAsConfigured(option: AutomaticSwitchOptions.EscapeBehavior) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        var options = fixture.options.read(); options.isEnabled = true; options.escapeBehavior = option
        fixture.options.write(options)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom", replacementRange: NSRange(location: NSNotFound, length: 0))
        await apps.send([]); try await eventually { fake.pendingCount == 1 }; fake.reply(.note)
        try await eventually { interaction.mode == .note }
        editor.keyDown(with: try escapeKey())
        if option == .returnsToSearch {
            #expect(interaction.mode == .search && interaction.currentInvocation == invocation && editor.string == "call mom")
            editor.keyDown(with: try escapeKey())
            #expect(fixture.log.counts().wrongSwitches == 1 && fixture.log.counts().ambiguous == 0)
        } else { #expect(fixture.log.counts().wrongSwitches == 0 && fixture.log.counts().ambiguous == 1) }
        #expect(interaction.currentInvocation == nil)
        await store.close()
    }

    @Test(arguments: [false, true])
    func escapeDuringAutomaticSaveUsesSafeDismissalWithoutCountingAReversal(saved: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let gate = CommitGate(); defer { gate.open() }
        let store = try await CollectionStore.open(storage.location,
            faults: .init(beforeCommit: { _ in gate.pass() }))
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        var options = fixture.options.read(); options.isEnabled = true; options.enterBehavior = .saves
        fixture.options.write(options)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            collection: Task { store }, confirmationDuration: .seconds(30), automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom tomorrow", replacementRange: NSRange(location: NSNotFound, length: 0))
        await apps.send([]); try await eventually { fake.pendingCount == 1 }; fake.reply(.note)
        try await eventually { interaction.mode == .note }
        editor.keyDown(with: try returnKey())
        try await eventually { gate.arrivals == 1 }
        #expect(interaction.modeLabelText == "Saving…")
        if saved {
            gate.open()
            try await eventually { interaction.modeLabelText == "Saved" }
        }
        editor.keyDown(with: try escapeKey())
        #expect(fixture.log.counts().wrongSwitches == 0 && fixture.log.counts().reversals == 0)
        if saved {
            #expect(interaction.currentInvocation == nil)
        } else {
            #expect(interaction.currentInvocation == invocation && interaction.modeLabelText == "Saving…")
            #expect(editor.window?.isKeyWindow == false)
            gate.open()
            // Deferred dismissal closes as soon as the outcome is known, without the 30-second confirmation.
            try await eventually { interaction.currentInvocation == nil }
        }
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.map(\.body) == ["call mom tomorrow"] && records.tasks.isEmpty)
        #expect(fixture.log.counts().ambiguous == 0)
        let rows = try String(contentsOf: fixture.log.url, encoding: .utf8).split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(rows.filter { $0["event"] as? String == "autoswitch.ended" }.count == 1)
        #expect(rows.first { $0["event"] as? String == "autoswitch.ended" }?["end"] as? String == "saved")
        await store.close()
    }

    @Test func missedManualCaptureRecordsTheLastSearchVerdictLabel() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        var options = fixture.options.read(); options.isEnabled = true; fixture.options.write(options)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("private unmatched lookup", replacementRange: NSRange(location: NSNotFound, length: 0))
        await apps.send([]); try await eventually { fake.pendingCount == 1 }; fake.reply(.search)
        try await eventually { (try? String(contentsOf: fixture.log.url, encoding: .utf8).contains("autoswitch.verdict")) == true }
        interaction.requestSelectedOpen()
        #expect(interaction.mode == .note && fixture.log.counts().missed == 1)
        let lines = try String(contentsOf: fixture.log.url, encoding: .utf8).split(separator: "\n")
        let rows = try lines.map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(rows.first { $0["event"] as? String == "autoswitch.missed" }?["lastVerdict"] as? String == "search")
        await store.close()
    }

    private func editor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }

    @MainActor private struct Fixture {
        let name = "Hana.AutomaticSwitchNativeTests.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let options: AutomaticSwitchOptionsStore
        let log: AutomaticSwitchDiagnostics
        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            options = AutomaticSwitchOptionsStore(defaults: defaults)
            log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        }
        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
