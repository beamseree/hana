import Foundation
import Observation

@MainActor @Observable
final class NotePreviewSession {
    private(set) var isVisible = false
    private(set) var isParsing = false
    private(set) var document: MarkdownPreviewDocument?
    private(set) var renderedTextRevision: UInt64?
    private let editing: NoteEditingSession
    private let parser: MarkdownPreviewParser
    @ObservationIgnored private var parsing: Task<Void, Never>?
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var requestedRevision: UInt64?

    init(editing: NoteEditingSession, parser: @escaping MarkdownPreviewParser = MarkdownPreview.parse) {
        self.editing = editing
        self.parser = parser
        watchEditing()
    }

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if visible { requestParse() }
        else {
            requestID = UUID()
            requestedRevision = nil
            parsing?.cancel()
            parsing = nil
            isParsing = false
            document = nil
            renderedTextRevision = nil
        }
    }

    private func watchEditing() {
        withObservationTracking {
            _ = editing.textRevision
            _ = editing.isClosed
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.watchEditing() }
        }
        if editing.isClosed { setVisible(false) }
        else if isVisible { requestParse() }
    }

    private func requestParse() {
        guard !editing.isClosed else { return }
        let revision = editing.textRevision
        guard requestedRevision != revision else { return }
        let text = editing.text
        let request = UUID()
        requestedRevision = revision
        requestID = request
        parsing?.cancel()
        document = nil
        renderedTextRevision = nil
        isParsing = true
        parsing = Task { [weak self, parser] in
            let result = await parser(text)
            guard let self, requestID == request, isVisible, !editing.isClosed,
                  editing.textRevision == revision else { return }
            document = result
            renderedTextRevision = revision
            isParsing = false
        }
    }

    isolated deinit { parsing?.cancel() }
}
