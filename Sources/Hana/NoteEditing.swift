import Foundation
import Observation

enum NoteOrganizationAction: Sendable {
    case setPinned(Bool), archive, restore

    func command(_ id: UUID, revision: Int64) -> CollectionCommand<Note> {
        switch self {
        case .setPinned(let pinned): .setNotePinned(id, pinned, expectedRevision: revision)
        case .archive: .archiveNote(id, expectedRevision: revision)
        case .restore: .restoreNote(id, expectedRevision: revision)
        }
    }
}

enum NoteOrganizationError: Error, Equatable { case unavailable, compositionActive }

/// The collection's public editing boundary: one revision-owning session per note.
@MainActor
final class NoteEditing {
    private let store: CollectionStore
    private let now: () -> Duration
    private let sleep: (Duration) async throws -> Void
    private struct SessionReference { weak var value: NoteEditingSession? }
    private var sessions: [UUID: SessionReference] = [:]
    // Untouched openings may disappear with their last caller. Once edited,
    // this owner keeps the draft through flush/failure until explicit close.
    private var editedSessions: [UUID: NoteEditingSession] = [:]
    private var openings: [UUID: Task<NoteEditingSession, any Error>] = [:]

    init<C: Clock>(store: CollectionStore, clock: C) where C.Duration == Duration {
        self.store = store
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(until: origin.advanced(by: $0), tolerance: nil) }
    }

    convenience init(store: CollectionStore) { self.init(store: store, clock: ContinuousClock()) }

    func open(_ noteID: UUID) async throws -> NoteEditingSession {
        if let session = sessions[noteID]?.value, !session.isClosed { return session }
        if let opening = openings[noteID] { return try await opening.value }
        let opening = Task {
            guard let note = try await store.read(.note(noteID), in: store.generation) else {
                throw CollectionStoreError.noteNotFound
            }
            let session = NoteEditingSession(note: note, store: store, now: now, sleep: sleep)
            sessions = sessions.filter { $0.value.value != nil }
            sessions[noteID] = SessionReference(value: session)
            session.onEdit = { [weak self] edited in self?.editedSessions[noteID] = edited }
            session.onClose = { [weak self] closed in
                guard self?.sessions[noteID]?.value === closed else { return }
                self?.sessions[noteID] = nil
                self?.editedSessions[noteID] = nil
            }
            return session
        }
        openings[noteID] = opening
        defer { openings[noteID] = nil }
        return try await opening.value
    }

    func flush() async throws {
        var firstFailure: (any Error)?
        for session in sessions.values.compactMap(\.value) where !session.isClosed {
            do { try await session.flush() } catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
    }

    func existingSession(_ id: UUID) -> NoteEditingSession? {
        guard let session = sessions[id]?.value, !session.isClosed else { return nil }
        return session
    }
}

@MainActor @Observable
final class NoteEditingSession {
    enum SaveState: Equatable {
        case saved, dirty, saving, blank, readOnly, invalidated
        case failed(CollectionStoreError)
    }

    enum FlushError: Error, Equatable { case compositionActive }

    static let blankExplanation = "Empty notes aren't saved. Archive the note to remove it."
    private(set) var textRevision: UInt64 = 0
    private(set) var text: String
    private(set) var committed: Note
    private(set) var state: SaveState
    private(set) var isComposing = false
    private(set) var isClosed = false
    fileprivate var onEdit: ((NoteEditingSession) -> Void)?
    fileprivate var onClose: ((NoteEditingSession) -> Void)?
    private(set) var isOrganizing = false
    var canOrganize: Bool { !isOrganizing && !isEditingSuspended && !isClosing && !isClosed && state != .invalidated }
    private(set) var isEditingSuspended = false
    private(set) var isClosing = false
    var isEditable: Bool { !isOrganizing && !isEditingSuspended && !isClosing && !isClosed && state != .invalidated && committed.archivedAt == nil }
    var hasUnsavedChanges: Bool { !sameBytes(text, committed.body) && Note.isNonblank(text) }
    var canRetry: Bool { if case .failed = state { true } else { false } }
    var status: String {
        if isOrganizing, state != .invalidated { return "Organizing…" }
        return switch state {
        case .saved: "Saved"
        case .dirty: "Unsaved changes"
        case .saving: "Saving…"
        default: explanation ?? "Unsaved changes"
        }
    }
    var explanation: String? {
        switch state {
        case .blank: Self.blankExplanation
        case .readOnly: "This note is archived. Restore it to edit."
        case .invalidated: "The collection is no longer available. Copy your text before closing and reopen Hana to continue."
        case .failed(let reason): Self.failureMessage(reason)
        default: nil
        }
    }
    private let store: CollectionStore
    private let generation: StoreGeneration
    private let now: () -> Duration
    private let sleep: (Duration) async throws -> Void
    private var inFlightBody: String?
    private var dirtySince: Duration?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var saving: Task<Void, any Error>?
    @ObservationIgnored private var observation: Task<Void, Never>?

    fileprivate init(note: Note, store: CollectionStore, now: @escaping () -> Duration,
                     sleep: @escaping (Duration) async throws -> Void) {
        text = note.body
        committed = note
        state = note.archivedAt == nil ? .saved : .readOnly
        self.store = store
        generation = store.generation
        self.now = now
        self.sleep = sleep
        observation = Task { [weak self, store, generation] in
            do {
                for try await note in store.observe(.note(note.id), in: generation) {
                    guard let self, !Task.isCancelled else { return }
                    guard let note else { self.invalidate(); return }
                    self.receive(note)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.invalidate()
            }
        }
    }

    func suspendEditing(_ suspended: Bool) { isEditingSuspended = suspended }

    func edit(_ text: String, isComposing: Bool = false) {
        guard isEditable else { return }
        onEdit?(self)
        if !sameBytes(self.text, text) { textRevision += 1 }
        self.text = text
        self.isComposing = isComposing
        timer?.cancel()
        if sameBytes(text, committed.body) {
            dirtySince = nil
            state = saving == nil ? .saved : .saving
            return
        }
        dirtySince = dirtySince ?? now()
        if case .failed = state, Note.isNonblank(text) { return }
        state = Note.isNonblank(text) ? (saving == nil ? .dirty : .saving) : .blank
        guard !isComposing, Note.isNonblank(text) else { return }
        let deadline = min(now() + .milliseconds(300), (dirtySince ?? now()) + .seconds(1))
        timer = Task { [weak self, sleep] in
            do { try await sleep(deadline) } catch { return }
            guard let self, !Task.isCancelled else { return }
            try? await self.flush()
        }
    }

    func flush() async throws {
        timer?.cancel()
        timer = nil
        guard !isClosed else { return }
        if state == .invalidated {
            if hasUnsavedChanges { throw CollectionStoreError.closed }
            return
        }
        guard !isComposing else { throw FlushError.compositionActive }
        if let saving {
            try await saving.value
            try await flush()
            return
        }
        if committed.archivedAt != nil {
            if hasUnsavedChanges { throw CollectionStoreError.archivedNote }
            return
        }
        guard Note.isNonblank(text) else { state = .blank; return }
        guard !sameBytes(text, committed.body) else { state = .saved; dirtySince = nil; return }
        let operation = Task { [self] in
            defer { saving = nil; inFlightBody = nil }
            // One operation owns the entire drain. Edits arriving during a commit
            // stay dirty and use that commit's revision for the next submission.
            while !isClosed, state != .invalidated, !sameBytes(text, committed.body), Note.isNonblank(text), !isComposing {
                let body = text
                let revision = committed.revision
                inFlightBody = body
                state = .saving
                do {
                    let note = try await store.perform(.editNote(committed.id, expectedRevision: revision, body: body), in: generation)
                    guard !isClosed, state != .invalidated else { throw CollectionStoreError.closed }
                    if note.revision >= committed.revision { committed = note }
                } catch {
                    let reason = error as? CollectionStoreError ?? .storageFailure(code: 0)
                    guard !isClosed else { throw error }
                    if reason == .closed || reason == .staleGeneration { invalidate() }
                    else if state != .invalidated {
                        // A lost acknowledgment can follow an actual commit.
                        // Adopt its revision only when the submitted bytes are
                        // present, so Retry never writes them twice or goes stale.
                        if let saved = try? await store.read(.note(committed.id), in: generation),
                           !isClosed, state != .invalidated, saved.revision > revision, sameBytes(saved.body, body) {
                            committed = saved
                        }
                        if !isClosed, state != .invalidated { state = .failed(reason) }
                    }
                    throw error
                }
            }
            guard !isClosed, state != .invalidated else { throw CollectionStoreError.closed }
            if isComposing { throw FlushError.compositionActive }
            dirtySince = nil
            state = !Note.isNonblank(text) ? .blank : (sameBytes(text, committed.body) ? .saved : .dirty)
        }
        saving = operation
        try await operation.value
    }

    func retry() async throws { try await flush() }

    /// Cancels this session's uncommitted transaction and any later drain.
    /// A transaction already committed is retained as saved collection state.
    func discardChanges() {
        isClosed = true
        onClose?(self)
        onClose = nil
        timer?.cancel()
        saving?.cancel()
        observation?.cancel()
    }

    func close() async throws {
        isClosing = true
        defer { isClosing = false }
        try await flush()
        isClosed = true
        onClose?(self)
        onClose = nil
        timer?.cancel()
        observation?.cancel()
    }

    /// Freeze before flushing: no edit can arrive between the body commit and
    /// the metadata command. Quit suspension is a separate editing reason.
    func organize(_ action: NoteOrganizationAction) async throws {
        guard canOrganize else { throw NoteOrganizationError.unavailable }
        guard !isComposing else { throw NoteOrganizationError.compositionActive }
        isOrganizing = true
        defer { isOrganizing = false }
        try await flush()
        guard !isClosed, state != .invalidated else { throw CollectionStoreError.closed }
        let note = try await store.perform(action.command(committed.id, revision: committed.revision), in: generation)
        guard !isClosed, state != .invalidated else { throw CollectionStoreError.closed }
        if note.revision >= committed.revision { committed = note }
        if committed.archivedAt != nil {
            if !sameBytes(text, committed.body) { text = committed.body; textRevision += 1 }
            state = .readOnly
        } else {
            state = Note.isNonblank(text) ? .saved : .blank
        }
    }

    private func receive(_ note: Note) {
        guard !isClosed, state != .invalidated, note.revision > committed.revision else { return }
        // Our own commit may be observed before perform returns. Preserve every
        // unsaved byte; only a clean session adopts another surface's body.
        let clean = sameBytes(text, committed.body) && saving == nil
        guard clean || sameBytes(note.body, committed.body) || inFlightBody.map({ sameBytes(note.body, $0) }) == true else {
            state = .failed(.staleRevision)
            timer?.cancel()
            return
        }
        committed = note
        if clean {
            if !sameBytes(text, note.body) { textRevision += 1 }
            text = note.body
        }
        if note.archivedAt != nil { state = .readOnly; timer?.cancel() }
        else if state == .readOnly {
            state = !Note.isNonblank(text) ? .blank : (sameBytes(text, note.body) ? .saved : .dirty)
        }
    }

    private func invalidate() {
        timer?.cancel()
        state = .invalidated
    }

    private static func failureMessage(_ reason: CollectionStoreError) -> String {
        let detail: String = switch reason {
        case .storageFailure(code: 13): "The disk is full."
        case .storageFailure(code: 8): "The collection is read-only."
        case .storageFailure(code: 10): "An input/output error interrupted the save."
        case .storageFailure(code: 5), .storageFailure(code: 6): "The collection is busy."
        case .staleRevision: "This note changed elsewhere."
        case .archivedNote: "This note is archived."
        case .noteNotFound: "This note is no longer in the collection."
        default: "The collection couldn’t complete the save."
        }
        return "\(detail) Your text is still here. Retry or copy it before closing."
    }

    private func sameBytes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    deinit { timer?.cancel(); observation?.cancel() }
}
