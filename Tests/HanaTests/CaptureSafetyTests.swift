import Foundation
import Testing
@testable import Hana

struct CaptureSafetyTests {
    @Test(arguments: [CaptureSession.Mode.note, .task])
    func dismissalWaitsForAnUnknownOutcomeWithoutAnotherSave(mode: CaptureSession.Mode) throws {
        var session = captureFixture(mode)
        let operation = session.operation
        _ = session.handle(.submit)
        #expect(session.handle(.dismissed).isEmpty)
        #expect(session.state.phase == .saving)
        #expect(session.state.text == "original")
        #expect(session.operation == operation)
        #expect(session.handle(.submit).isEmpty)
        #expect(session.handle(.saved) == [.closeSaved])
        #expect(session.state.phase == .saved)
        #expect(session.handle(.saved).isEmpty)
    }

    @Test(arguments: [CaptureSession.Mode.note, .task])
    func failedDismissalKeepsTheCaptureAndAnUnchangedRetryKeepsItsOperation(mode: CaptureSession.Mode) {
        var session = captureFixture(mode)
        let operation = session.operation
        let first = session.handle(.submit)
        _ = session.handle(.dismissed)
        _ = session.handle(.dismissed)
        #expect(session.handle(.submit).isEmpty)
        #expect(session.handle(.saveFailed(.failed)).isEmpty)
        #expect(session.state.phase == .editing && session.state.notice == .failed)
        #expect(session.state.text == "original")
        // Selection changes are not payload changes.
        _ = session.handle(.edited(text: "original", selection: NSRange(location: 0, length: 0)))
        #expect(session.operation == operation)
        #expect(session.handle(.submit) == first)
        #expect(session.handle(.submit).isEmpty)
    }

    @Test(arguments: [CaptureSession.Mode.note, .task], ["edited", "Café"])
    func editingAFailedCaptureStartsANewOperationIncludingCanonicalUnicode(mode: CaptureSession.Mode, text: String) {
        var session = captureFixture(mode, text: "Cafe\u{301}")
        let operation = session.operation
        _ = session.handle(.submit)
        _ = session.handle(.saveFailed(.failed))
        _ = session.handle(.edited(text: text, selection: NSRange(location: 0, length: 0)))
        #expect(session.operation != operation)
        #expect(session.state.notice == nil)
        #expect(session.handle(.submit) == (mode == .note
            ? [.saveNote(operation: session.operation, body: text)]
            : [.saveTask(operation: session.operation, title: text, placement: .inbox)]))
    }

    @Test func changingAFailedTasksDestinationStartsANewOperation() {
        var session = captureFixture(.task)
        let operation = session.operation
        _ = session.handle(.submit)
        _ = session.handle(.saveFailed(.failed))
        _ = session.handle(.chooseDestination(.inbox))
        #expect(session.operation == operation)
        _ = session.handle(.chooseDestination(.today))
        #expect(session.operation != operation)
        #expect(session.state.notice == nil)
        #expect(session.handle(.submit) == [.saveTask(operation: session.operation, title: "original", placement: .today)])
    }

    @Test func changingAFailedNotesModeStartsANewOperation() {
        var session = captureFixture(.note)
        let operation = session.operation
        _ = session.handle(.submit)
        _ = session.handle(.saveFailed(.failed))
        _ = session.handle(.edited(text: "original", selection: NSRange(location: 0, length: 0)))
        _ = session.handle(.deleteBackward)
        // Empty Search re-arms typed prefixes.
        _ = session.handle(.edited(text: "", selection: NSRange(location: 0, length: 0)))
        _ = session.handle(.insert("[", replacing: NSRange(location: 0, length: 0), provenance: .typed))
        _ = session.handle(.edited(text: "original", selection: NSRange(location: 8, length: 0)))
        #expect(session.operation != operation)
        #expect(session.handle(.submit) == [.saveTask(operation: session.operation, title: "original", placement: .inbox)])
    }

    @Test(arguments: [CaptureSession.Mode.note, .task])
    func aLostCommitAcknowledgementThenRetryCreatesExactlyOneItem(mode: CaptureSession.Mode) async throws {
        let fixture = try TemporaryFixture()
        let fail = FailOnce()
        let store = try await CollectionStore.open(fixture.location, faults: .init(afterCommit: {
            if fail.take() { throw InjectedFailure() }
        }))
        var session = captureFixture(mode)
        let first = try #require(session.handle(.submit).first)
        await #expect(throws: InjectedFailure.self) { try await saveCapture(first, to: store) }
        _ = session.handle(.saveFailed(.failed))
        let retry = try #require(session.handle(.submit).first)
        #expect(retry == first)
        let id = try await saveCapture(retry, to: store)
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.count + records.tasks.count == 1)
        #expect(records.notes.first?.id == id || records.tasks.first?.id == id)
        _ = session.handle(.saved)
        #expect(session.handle(.submit).isEmpty)
        await store.close()
    }

    @Test(arguments: [CaptureSession.Mode.note, .task])
    func aRolledBackSaveThenEditingCreatesOnlyTheEditedItem(mode: CaptureSession.Mode) async throws {
        let fixture = try TemporaryFixture()
        let fail = FailOnce()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if fail.take() { throw InjectedFailure() }
        }))
        var session = captureFixture(mode)
        let operation = session.operation
        let first = try #require(session.handle(.submit).first)
        await #expect(throws: InjectedFailure.self) { try await saveCapture(first, to: store) }
        _ = session.handle(.saveFailed(.failed))
        _ = session.handle(.edited(text: "edited", selection: NSRange(location: 6, length: 0)))
        #expect(session.operation != operation)
        _ = try await saveCapture(try #require(session.handle(.submit).first), to: store)
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.count + records.tasks.count == 1)
        #expect(records.notes.first?.body == "edited" || records.tasks.first?.title == "edited")
        await store.close()
    }
}

extension CaptureSafetyTests {
    @Test(arguments: [CaptureSession.Mode.note, .task])
    @MainActor
    func aPausedRealStoreKeepsSavingAndSerializesDismissal(mode: CaptureSession.Mode) async throws {
        let fixture = try TemporaryFixture()
        let gate = CommitGate()
        defer { gate.open() }
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in gate.pass() }))
        var session = captureFixture(mode)
        let effect = try #require(session.handle(.submit).first)
        let saving = Task { try await saveCapture(effect, to: store) }
        try await eventually { gate.arrivals == 1 }
        #expect(session.state.phase == .saving)
        _ = session.handle(.dismissed)
        #expect(session.handle(.submit).isEmpty)
        #expect(session.state.text == "original")
        gate.open()
        _ = try await saving.value
        #expect(session.handle(.saved) == [.closeSaved])
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.count + records.tasks.count == 1)
        await store.close()
    }
}

func captureFixture(_ mode: CaptureSession.Mode, text: String = "original") -> CaptureSession {
    var session = CaptureSession()
    _ = session.handle(.automaticMode(mode))
    _ = session.handle(.edited(text: text, selection: NSRange(location: (text as NSString).length, length: 0)))
    return session
}

/// Performs only the public save effects against the real temporary Store.
func saveCapture(_ effect: CaptureSession.Effect, to store: CollectionStore) async throws -> UUID {
    switch effect {
    case .saveNote(let operation, let body):
        return try await store.perform(.createNote(operation: operation, body: body), in: store.generation).id
    case .saveTask(let operation, let title, let placement):
        return try await store.perform(.createTask(operation: operation, title: title, placement: placement), in: store.generation).id
    default:
        throw CocoaError(.coderInvalidValue)
    }
}
