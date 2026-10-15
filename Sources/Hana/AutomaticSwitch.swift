import Foundation

/// Pure session policy. Time is read only at events; the adapter supplies ticks.
struct AutomaticSwitch {
    enum Event {
        case invoked
        case dismissed(AutomaticSwitchDiagnostics.End)
        case bufferChanged(text: String, composing: Bool, gate: StrongMatchGate.Evaluation? = nil)
        case gateChanged(StrongMatchGate.Evaluation)
        case eligibilityChanged(Bool)
        case verdict(id: UUID, ClassifierVerdict, latencyMilliseconds: Double)
        case failed(id: UUID, AutomaticSwitchDiagnostics.ErrorKind, latencyMilliseconds: Double)
        case navigated
        case enter
        case reversed(AutomaticSwitchDiagnostics.ReversalMethod)
        case manualModeChanged(CaptureSession.Mode)
        case tick
    }
    enum Effect {
        case classify(id: UUID, text: String)
        case cancel(UUID)
        case enterMode(CaptureSession.Mode)
        case returnToSearch
        case swallowEnter
        case record(AutomaticSwitchDiagnostics.Event)
    }
    private struct Request { let id: UUID; let started: Duration }
    private struct Candidate { let verdict: ClassifierVerdict; let latency: Double? }
    let options: AutomaticSwitchOptions
    private let now: () -> Duration
    private var active = false
    private var text = ""
    private var composing = false
    private var eligible = true
    private var suspended = false
    private var mode = CaptureSession.Mode.search
    private var gate = StrongMatchGate.Evaluation(decision: .blocked(.collectionUnavailable), settled: false, allSourcesSettled: false)
    private var request: Request?
    // A timeout already sampled latency; retain the later stale row without sampling it again.
    private var timedOutRequests: Set<UUID> = []
    private var due: Duration?
    private var changedAt: Duration = .zero
    private var candidate: Candidate?
    private var agreementLabel: ClassifierVerdict.Label?
    private var agreements = 0
    private var switchedAt: Duration?
    private var hadSwitch = false
    private var actedOnText: String?
    var hasActedOnCurrentBuffer: Bool { actedOnText.map { $0.utf8.elementsEqual(text.utf8) } ?? false }
    private var ended = false
    private var lateKind: StrongMatchGate.Kind?
    private(set) var lastVerdict = AutomaticSwitchDiagnostics.Label.none
    var lastModeChangeWasAutomatic: Bool { switchedAt != nil }

    init(options: AutomaticSwitchOptions, now: @escaping () -> Duration) {
        self.options = options; self.now = now
    }

    mutating func handle(_ event: Event) -> [Effect] {
        guard options.isEnabled else { return [] }
        switch event {
        case .invoked:
            let effects = cancel()
            active = true; text = ""; composing = false; eligible = true; suspended = false
            mode = .search; candidate = nil; due = nil; agreements = 0; agreementLabel = nil
            timedOutRequests = []
            switchedAt = nil; hadSwitch = false; actedOnText = nil; ended = false; lastVerdict = .none; lateKind = nil
            return effects
        case .dismissed(let end):
            active = false; due = nil; candidate = nil
            var effects = cancel()
            if hadSwitch, !ended { effects.append(.record(.ended(end))); ended = true }
            return effects
        default: guard active else { return [] }
        }
        switch event {
        case .bufferChanged(let text, let composing, let newGate):
            guard !self.text.utf8.elementsEqual(text.utf8) || self.composing != composing else { return [] }
            if let newGate { gate = newGate }
            self.text = text; self.composing = composing; changedAt = now(); candidate = nil; lateKind = nil
            var effects = cancel()
            due = nil
            if suspended, !text.isEmpty, !composing { return effects + [diagnostic(nil, .suspended)] }
            guard !text.isEmpty, !composing, canClassify else { return effects }
            due = now() + firingDelay
            effects += fireIfDue()
            return effects
        case .gateChanged(let value):
            let wasBlocked = gate.decision != .allowed
            gate = value
            if switchedAt != nil, mode != .search, case .blocked(.strongMatch(let kind)) = gate.decision,
               lateKind != kind {
                if options.lateStrongMatch == .returnToSearch, !eligible || composing { return [] }
                lateKind = kind
                var effects: [Effect] = [.record(.lateStrongMatch(kind: diagnosticKind(kind),
                    outcome: options.lateStrongMatch == .stay ? .stayed : .returnedToSearch))]
                if options.lateStrongMatch == .returnToSearch, eligible, !composing {
                    effects += returnToSearch()
                }
                return effects
            }
            if let candidate { return apply(candidate) }
            if wasBlocked, gate.decision == .allowed, due == nil, request == nil,
               !text.isEmpty, !composing, canClassify {
                due = max(now(), changedAt + firingDelay)
            }
            return fireIfDue()
        case .eligibilityChanged(let value):
            eligible = value
            if !value { due = nil; candidate = nil; return cancel() }
            return []
        case .verdict(let id, let verdict, let latency):
            let value = Candidate(verdict: verdict, latency: latency)
            guard request?.id == id else { return [staleDiagnostic(id: id, value: value)] }
            if let timeout = timeoutIfDue() { return timeout }
            request = nil
            lastVerdict = diagnosticLabel(verdict.label)
            candidate = value
            return apply(value)
        case .failed(let id, let kind, let latency):
            guard request?.id == id else {
                return [staleDiagnostic(id: id, value: Candidate(verdict: .init(label: .unsure), latency: latency))]
            }
            if let timeout = timeoutIfDue() { return timeout }
            request = nil; candidate = nil; agreements = 0; agreementLabel = nil
            return [diagnostic(Candidate(verdict: .init(label: .unsure), latency: latency), .error, error: kind)]
        case .navigated:
            guard options.navigationSuspends else { return [] }
            suspended = true; candidate = nil; due = nil
            return cancel()
        case .enter:
            guard let switchedAt, options.enterBehavior == .ignoreFor300Milliseconds,
                  now() - switchedAt < .milliseconds(300) else { return [] }
            return [.swallowEnter]
        case .reversed(let method):
            guard eligible, !composing, let switchedAt, mode != .search,
                  method == .backspace || options.escapeBehavior == .returnsToSearch else { return [] }
            return returnToSearch(recording: .reversed(method: method,
                millisecondsSinceSwitch: milliseconds(now() - switchedAt)))
        case .manualModeChanged(let mode):
            self.mode = mode; switchedAt = nil; candidate = nil; due = nil
            return cancel()
        case .tick:
            if let timeout = timeoutIfDue() { return timeout }
            if let candidate { return apply(candidate) }
            return fireIfDue()
        case .invoked, .dismissed: return []
        }
    }

    /// Both reversal routes reset the same session state and end a switch once.
    private mutating func returnToSearch(recording event: AutomaticSwitchDiagnostics.Event? = nil) -> [Effect] {
        var effects = cancel()
        switchedAt = nil; mode = .search; candidate = nil; due = nil
        suspended = options.reversalSuspends; agreements = 0; agreementLabel = nil
        effects.append(.returnToSearch)
        if let event { effects.append(.record(event)) }
        if !ended { effects.append(.record(.ended(.reversed))); ended = true }
        return effects
    }

    private mutating func timeoutIfDue() -> [Effect]? {
        guard let request, now() - request.started >= .milliseconds(1500) else { return nil }
        self.request = nil; candidate = nil
        timedOutRequests.insert(request.id)
        return [.cancel(request.id), diagnostic(Candidate(verdict: .init(label: .unsure),
            latency: milliseconds(now() - request.started)), .timeout)]
    }

    private var firingDelay: Duration {
        switch options.firing { case .everyKeystroke: .zero; case .debounced: .milliseconds(150); case .onPause: .milliseconds(500) }
    }
    private var canClassify: Bool { eligible && !suspended && (mode == .search || options.afterSwitch == .keepClassifying && switchedAt != nil) }
    private mutating func cancel() -> [Effect] {
        guard let request else { return [] }
        self.request = nil
        return [.cancel(request.id)]
    }
    private mutating func fireIfDue() -> [Effect] {
        guard let due, now() >= due, request == nil, !composing, canClassify else { return [] }
        self.due = nil
        guard gate.decision == .allowed else {
            return [diagnostic(nil, .blocked)]
        }
        let id = UUID(); request = Request(id: id, started: now())
        return [.classify(id: id, text: text)]
    }
    private mutating func apply(_ value: Candidate) -> [Effect] {
        guard !suspended else { candidate = nil; return [diagnostic(value, .suspended)] }
        guard eligible, !composing, canClassify else { candidate = nil; return [diagnostic(value, .blocked)] }
        guard gate.decision == .allowed else { candidate = nil; agreements = 0; return [diagnostic(value, .blocked)] }
        // All-source waiting has a hard cap measured from the current edit.
        if options.wait == .allSources, !gate.allSourcesSettled, now() - changedAt < .seconds(1) { return [] }
        if options.wait == .appsAndCollection, !gate.settled { return [] }
        candidate = nil
        if value.verdict.label == .unsure { agreements = 0; return [diagnostic(value, .unsure)] }
        if options.classifier == .jev,
           !(value.verdict.probability.map { $0.isFinite && $0 >= options.jevThreshold.rawValue } ?? false) {
            agreements = 0; return [diagnostic(value, .belowThreshold)]
        }
        let target: CaptureSession.Mode = switch value.verdict.label {
        case .search, .unsure: .search; case .note: .note; case .task: .task
        }
        if target == .task, TaskItem.isMultiline(text) { agreements = 0; return [diagnostic(value, .multiline)] }
        guard target != mode else { agreements = 0; return [diagnostic(value, .blocked)] }
        if agreementLabel == value.verdict.label { agreements += 1 }
        else { agreementLabel = value.verdict.label; agreements = 1 }
        if agreements < options.agreeingVerdicts.rawValue {
            due = now() + max(firingDelay, .milliseconds(150))
            return [diagnostic(value, .awaitingAgreement)]
        }
        mode = target; switchedAt = target == .search ? nil : now(); hadSwitch = true; actedOnText = text; ended = false
        agreements = 0; agreementLabel = nil
        let transition: Effect = target == .search ? .returnToSearch : .enterMode(target)
        return [diagnostic(value, .switched), transition,
                .record(.switched(mode: AutomaticSwitchDiagnostics.Mode(rawValue: target.rawValue)!))]
    }
    private func staleDiagnostic(id: UUID, value: Candidate) -> Effect {
        diagnostic(Candidate(verdict: value.verdict,
            latency: timedOutRequests.contains(id) ? nil : value.latency), .stale)
    }

    private func diagnostic(_ value: Candidate?, _ outcome: AutomaticSwitchDiagnostics.Outcome,
                            error: AutomaticSwitchDiagnostics.ErrorKind? = nil) -> Effect {
        var row = AutomaticSwitchDiagnostics.Verdict(classifier: options.classifier,
            label: value.map { diagnosticLabel($0.verdict.label) } ?? .none,
            latencyMilliseconds: value?.latency, outcome: outcome, errorKind: error,
            wordCount: text.split(whereSeparator: \.isWhitespace).count)
        if let value { row.wordingVersion = value.verdict.wordingVersion; row.probability = value.verdict.probability; row.unsure = value.verdict.label == .unsure }
        if case .blocked(let reason) = gate.decision {
            switch reason {
            case .oneWord: row.gateReason = .oneWord
            case .collectionUnavailable: row.gateReason = .collectionUnavailable
            case .strongMatch(let kind): row.gateReason = .strongMatch; row.matchedKind = diagnosticKind(kind)
            }
        }
        return .record(.verdict(row))
    }
    private func diagnosticLabel(_ label: ClassifierVerdict.Label) -> AutomaticSwitchDiagnostics.Label {
        switch label { case .search: .search; case .note: .note; case .task: .task; case .unsure: .unsure }
    }
    private func diagnosticKind(_ kind: StrongMatchGate.Kind) -> AutomaticSwitchDiagnostics.MatchedKind {
        switch kind { case .application: .application; case .note: .note; case .task: .task; case .file: .file }
    }
    private func milliseconds(_ value: Duration) -> Double {
        Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15
    }
}
