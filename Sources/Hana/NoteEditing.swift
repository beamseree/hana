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
    private var sessions: [UUID: NoteEditingSession] = [:]
    private var openings: [UUID: Task<NoteEditingSession, any Error>] = [:]

    init<C: Clock>(store: CollectionStore, clock: C) where C.Duration == Duration {
        self.store = store
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(until: origin.advanced(by: $0), tolerance: nil) }
    }

    convenience init(store: CollectionStore) { self.init(store: store, clock: ContinuousClock()) }

    func open(_ noteID: UUID) async throws -> NoteEditingSession {
        if let session = sessions[noteID], !session.isClosed { return session }
        if let opening = openings[noteID] { return try await opening.value }
        let opening = Task {
            guard let note = try await store.read(.note(noteID), in: store.generation) else {
                throw CollectionStoreError.noteNotFound
            }
            return NoteEditingSession(note: note, store: store, now: now, sleep: sleep)
        }
        openings[noteID] = opening
        defer { openings[noteID] = nil }
        let session = try await opening.value
        sessions[noteID] = session
        return session
    }

    func flush() async throws {
        for session in sessions.values where !session.isClosed { try await session.flush() }
    }

    func existingSession(_ id: UUID) -> NoteEditingSession? {
        guard let session = sessions[id], !session.isClosed else { return nil }
        return session
    }
}

@MainActor @Observable
final class NoteEditingSession {
    enum SaveState: Equatable {
        case saved, dirty, saving, blank, readOnly, invalidated
        case failed(CollectionStoreError)
    }

    static let blankExplanation = "Empty notes aren't saved. Archive the note to remove it."
    private(set) var textRevision: UInt64 = 0
    private(set) var text: String
    private(set) var committed: Note
    private(set) var state: SaveState
    private(set) var isComposing = false
    private(set) var isClosed = false
    private(set) var isOrganizing = false
    var canOrganize: Bool { !isOrganizing && !isClosed && state != .invalidated }
    var isEditable: Bool { !isOrganizing && !isClosed && state != .invalidated && committed.archivedAt == nil }
    var explanation: String? {
        switch state {
        case .blank: Self.blankExplanation
        case .readOnly: "This note is archived. Restore it to edit."
        case .invalidated: "The collection is no longer available. Reopen the note to continue."
        case .failed(let reason): "The note couldn’t be saved (\(reason)). Your text is still here."
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

    func edit(_ text: String, isComposing: Bool = false) {
        guard isEditable else { return }
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
        if let saving { try await saving.value; return }
        guard !isClosed, state != .invalidated, !isComposing, committed.archivedAt == nil else { return }
        guard Note.isNonblank(text) else { state = .blank; return }
        guard !sameBytes(text, committed.body) else { state = .saved; dirtySince = nil; return }
        let operation = Task { [self] in
            // One operation owns the entire drain. Edits arriving during a commit
            // stay dirty and use that commit's revision for the next submission.
            while !sameBytes(text, committed.body), Note.isNonblank(text), !isComposing {
                let body = text
                let revision = committed.revision
                inFlightBody = body
                state = .saving
                do {
                    let note = try await store.perform(.editNote(committed.id, expectedRevision: revision, body: body), in: generation)
                    guard state != .invalidated else { return }
                    if note.revision >= committed.revision { committed = note }
                } catch {
                    let reason = error as? CollectionStoreError ?? .storageFailure(code: 0)
                    if reason == .closed || reason == .staleGeneration { invalidate() }
                    else { state = .failed(reason) }
                    throw error
                }
            }
            dirtySince = nil
            state = !Note.isNonblank(text) ? .blank : (sameBytes(text, committed.body) ? .saved : .dirty)
        }
        saving = operation
        defer { saving = nil; inFlightBody = nil }
        try await operation.value
    }

    func close() async throws {
        try await flush()
        isClosed = true
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
        guard note.revision > committed.revision else { return }
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
    }

    private func invalidate() {
        timer?.cancel()
        state = .invalidated
    }

    private func sameBytes(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    deinit { timer?.cancel(); observation?.cancel() }
}
