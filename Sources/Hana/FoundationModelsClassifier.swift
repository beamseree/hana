import Foundation
import FoundationModels

enum FoundationModelAvailability: Equatable {
    case available, deviceNotEligible, appleIntelligenceOff, modelNotReady, unknown
    var menuText: String? {
        switch self {
        case .available: nil
        case .deviceNotEligible: "Mac not eligible for Apple Intelligence"
        case .appleIntelligenceOff: "Apple Intelligence is off"
        case .modelNotReady: "Foundation Models is not ready"
        case .unknown: "Foundation Models is unavailable"
        }
    }
    static func live() -> Self {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: .deviceNotEligible
            case .appleIntelligenceNotEnabled: .appleIntelligenceOff
            case .modelNotReady: .modelNotReady
            @unknown default: .unknown
            }
        @unknown default: .unknown
        }
    }
}

/// Session lifetime is the system boundary: one response per session, including the warmed one.
@MainActor
struct FoundationModelSession {
    let prewarm: () -> Void
    let respond: (String) async throws -> ClassifierVerdict.Label
}

@Generable private enum FoundationLabel { case search, note, task }
@Generable private enum FoundationLabelWithUnsure { case search, note, task, unsure }

@MainActor
final class FoundationModelsClassifier: Classifier {
    private let availability: () -> FoundationModelAvailability
    private let makeSession: () -> FoundationModelSession
    private var warmedSession: FoundationModelSession?
    init(unsure: Bool, availability: @escaping () -> FoundationModelAvailability = FoundationModelAvailability.live,
         makeSession: (() -> FoundationModelSession)? = nil) {
        self.availability = availability
        self.makeSession = makeSession ?? { Self.liveSession(unsure: unsure) }
    }
    func prewarm() {
        guard availability() == .available, warmedSession == nil else { return }
        let session = makeSession()
        session.prewarm()
        warmedSession = session
    }
    func classify(_ text: String) async throws -> ClassifierVerdict {
        try Task.checkCancellation()
        guard availability() == .available else {
            warmedSession = nil
            throw ClassifierFailure(kind: .unavailable)
        }
        let session = warmedSession ?? makeSession()
        warmedSession = nil
        do {
            let label = try await session.respond(text)
            try Task.checkCancellation()
            return ClassifierVerdict(label: label, wordingVersion: ClassifierWording.version)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw CancellationError() }
            if let failure = error as? ClassifierFailure { throw failure }
            throw ClassifierFailure(kind: .other)
        }
    }
    private static func liveSession(unsure: Bool) -> FoundationModelSession {
        let session = LanguageModelSession(instructions: ClassifierWording.foundationInstructions(unsure: unsure))
        return FoundationModelSession(prewarm: { session.prewarm() }, respond: { text in
            do {
                if unsure {
                    let label = try await session.respond(to: text, generating: FoundationLabelWithUnsure.self,
                        options: GenerationOptions(sampling: .greedy)).content
                    switch label { case .search: return .search; case .note: return .note; case .task: return .task; case .unsure: return .unsure }
                } else {
                    let label = try await session.respond(to: text, generating: FoundationLabel.self,
                        options: GenerationOptions(sampling: .greedy)).content
                    switch label { case .search: return .search; case .note: return .note; case .task: return .task }
                }
            } catch LanguageModelSession.GenerationError.guardrailViolation {
                throw ClassifierFailure(kind: .guardrail)
            } catch LanguageModelSession.GenerationError.refusal {
                throw ClassifierFailure(kind: .refusal)
            }
        })
    }
}
