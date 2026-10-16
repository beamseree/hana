import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct CalculationInteractionTests {
    @Test(arguments: [
        ("12 *", "…", "Keep typing"),
        ("5 / 0", "Uh oh", "Can't divide by zero"),
        ("3 + * 4", "Not a valid calculation", "3 + * 4"),
        ("sqrt(-1)", "Uh oh", "Undefined"),
        ("9^9^9", "Uh oh", "Too large")
    ])
    func answerWithoutAValuePrecedesResultsButDefaultsToOpeningTheFirstResult(
        text: String, title: String, subtitle: String
    ) async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed()
        var opened: [URL] = [], copied: [String] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            launchApplication: { url in opened.append(url); return .init(activate: { true }) },
            copyAnswer: { copied.append($0) })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery(text)
        guard case .answer(let answer) = interaction.rows.first else { Issue.record("Expected an answer without a value"); return }
        #expect(answer.title == title && answer.subtitle == subtitle && answer.copyableText == nil)
        #expect(interaction.rows.map(\.id) == [.answer] && interaction.selectedRow == .answer)
        let application = app(text, "/fixture/Calculation.app")
        await apps.send([application])
        try await eventually { interaction.results == [application] }
        #expect(interaction.rows == [.answer(answer), .result(application)])
        #expect(interaction.selectedResult == application)
        await interaction.requestSelectedOpen()?.value
        #expect(opened == [application.url] && copied.isEmpty)
        #expect(interaction.currentInvocation == nil)
    }

    @Test(arguments: [false, true])
    func completingACalculationSelectsItsValueUnlessTheUserNavigated(userNavigated: Bool) async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let first = app("12 * 4 A", "/fixture/First.app"), second = app("12 * 4 B", "/fixture/Second.app")
        interaction.updateQuery("12 *")
        await apps.send([first, second])
        try await eventually { interaction.results == [first, second] }
        try await eventually { files.subscriptionCount == 1 }
        #expect(interaction.selectedResult == first)
        if userNavigated {
            interaction.moveSelection(by: 1)
            #expect(interaction.selectedResult == second)
        }
        interaction.updateQuery("12 * 4")
        guard case .answer(let answer) = interaction.rows.first else { Issue.record("Expected the completed answer"); return }
        #expect(answer.state == .value && answer.title == "48")
        let expected: SearchRow.ID = userNavigated ? .result(second.id) : .answer
        #expect(interaction.selectedRow == expected)
        try await eventually { apps.subscriptionCount == 2 && files.subscriptionCount == 2 }
        await apps.send([first, second])
        let file = SearchResult(name: "12 * 4.txt", url: URL(fileURLWithPath: "/fixture/12 * 4.txt"), kind: .file)
        await files.send([file], status: .loading)
        try await eventually { interaction.results.contains(file) }
        #expect(interaction.rows.first == .answer(answer))
        #expect(interaction.selectedRow == expected)
        await files.send([file])
        try await eventually { !interaction.isLoading }
        #expect(interaction.selectedRow == expected)
    }

    @Test(arguments: ["12 *", "5 / 0", "3 + * 4", "sqrt(-1)", "9^9^9"])
    func enterOnTheOnlyAnswerWithoutAValueDismissesLikeEscapeWithoutCopying(text: String) async throws {
        _ = NSApplication.shared
        var copied: [String] = []
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         copyAnswer: { copied.append($0) }, frontmostApplication: { .current })
        let origin = CalculationOriginPanel(contentRect: NSRect(x: 200, y: 200, width: 320, height: 80),
                                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 280, height: 24))
        origin.contentView?.addSubview(field)
        origin.makeKeyAndOrderFront(nil)
        #expect(origin.makeFirstResponder(field))
        try await eventually { NSApp.keyWindow === origin }
        let responder = try #require(origin.firstResponder)
        defer { origin.close() }
        _ = interaction.presentBar()
        defer { if let invocation = interaction.currentInvocation { interaction.dismiss(invocation, reason: .outsideClick) } }
        let editor = try await firstResponderEditor()
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.rows.map(\.id) == [.answer] && interaction.selectedRow == .answer)
        #expect(interaction.isLoading)
        editor.keyDown(with: try returnKey())
        #expect(copied.isEmpty && interaction.currentInvocation == nil)
        #expect(origin.isKeyWindow && origin.firstResponder === responder)
    }

    @Test(arguments: [("1200 / 3", "400"), ("sqrt(16)", "4")])
    func enterCopiesTheDefaultAnswerImmediatelyWhileSourcesLoadAndReturnsToTheOrigin(text: String, expected: String) async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        var copied: [String] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero),
                                         copyAnswer: { copied.append($0) }, frontmostApplication: { .current })
        let origin = CalculationOriginPanel(contentRect: NSRect(x: 200, y: 200, width: 320, height: 80),
                                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 280, height: 24))
        origin.contentView?.addSubview(field)
        origin.makeKeyAndOrderFront(nil)
        #expect(origin.makeFirstResponder(field))
        try await eventually { NSApp.keyWindow === origin }
        let responder = try #require(origin.firstResponder)
        defer { origin.close() }
        _ = interaction.presentBar()
        defer { if let invocation = interaction.currentInvocation { interaction.dismiss(invocation, reason: .outsideClick) } }
        let editor = try await firstResponderEditor()
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.rows.first == .answer(Answer(title: expected, subtitle: text, copyableText: expected)))
        #expect(interaction.selectedRow == .answer)
        #expect(interaction.isLoading)
        #expect(interaction.mode == .search && interaction.modeIconShowsQuery)
        editor.keyDown(with: try returnKey())
        #expect(copied == [expected])
        #expect(interaction.currentInvocation == nil)
        #expect(origin.isKeyWindow && origin.firstResponder === responder)
    }

    @Test func answerStaysAboveLateBatchesAndPreservesAnExplicitResultSelection() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        var opened: [URL] = []
        var copied: [String] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero),
            launchApplication: { url in opened.append(url); return .init(activate: { true }) },
            copyAnswer: { copied.append($0) })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let application = app("12 * 4", "/fixture/Arithmetic.app")
        let file = SearchResult(name: "12 * 4.txt", url: URL(fileURLWithPath: "/fixture/12 * 4.txt"), kind: .file)
        interaction.updateQuery("12 * 4")
        let answer = try #require(interaction.rows.first)
        #expect(answer.id == .answer && interaction.selectedRow == .answer)
        await apps.send([application])
        try await eventually { interaction.results == [application] }
        #expect(interaction.rows == [answer, .result(application)])
        #expect(interaction.selectedRow == .answer)
        await files.send([file], status: .loading)
        try await eventually { interaction.results == [application, file] }
        #expect(interaction.rows == [answer, .result(application), .result(file)])
        #expect(interaction.selectedRow == .answer)
        interaction.moveSelection(by: 1)
        #expect(interaction.selectedResult == application)
        await files.send([file])
        try await eventually { !interaction.isLoading }
        #expect(interaction.selectedResult == application)
        await interaction.requestSelectedOpen()?.value
        #expect(opened == [application.url] && copied.isEmpty)
        #expect(interaction.currentInvocation == nil)
    }

    @Test func suggestionsReturnAsSoonAsTheTextGainsAWord() async throws {
        _ = NSApplication.shared
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery("1200 / 3")
        #expect(interaction.rows.map(\.id) == [.answer])
        interaction.updateQuery("rent 1200 / 3")
        #expect(interaction.rows.map(\.id) == [.suggestion(.note), .suggestion(.task)])
    }

    @Test(arguments: [CaptureSession.Mode.note, .task])
    func calculationsStayPlainTextInCapture(mode: CaptureSession.Mode) async throws {
        _ = NSApplication.shared
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        if mode == .note { try enterNoteCaptureForValidation(interaction, editor: editor) }
        else { editor.insertText("[", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        editor.insertText("12 * 4", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.mode == mode && editor.string == "12 * 4")
        #expect(interaction.rows.isEmpty && !interaction.resultsVisible)
    }

    @Test func pastedNegativeCalculationWorksAndEditorCopyRemainsOrdinary() async throws {
        _ = NSApplication.shared
        var copied: [String] = []
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         copyAnswer: { copied.append($0) })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
        pasteboard.clearContents()
        try #require(pasteboard.setString("-5 + 3", forType: .string))
        editor.paste(nil)
        #expect(interaction.mode == .search && interaction.selectedRow == .answer)
        guard case .answer(let answer) = interaction.rows.first else { Issue.record("Expected a pasted answer"); return }
        #expect(answer.title == "-2")
        editor.setSelectedRange(NSRange(location: 1, length: 1))
        editor.copy(nil)
        #expect(pasteboard.string(forType: .string) == "5")
        #expect(copied.isEmpty && interaction.currentInvocation == invocation)
    }

    private func firstResponderEditor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
}

private final class CalculationOriginPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
