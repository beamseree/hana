import Foundation

/// Pure session policy. Time is read only at events. After each event the
/// adapter reads `nextWakeUp` and sends `.tick` at that time, never periodically.
struct AutomaticSwitch {
    /// Native edit provenance is necessary: replacing a selection can leave
    /// text that looks like a suffix append, or even the same text.
    enum Edit: Equatable {
        case append
        case replacement(caretAtEnd: Bool)
    }
    enum Event {
        case invoked
        case dismissed(AutomaticSwitchDiagnostics.End)
        case bufferChanged(text: String, composing: Bool, gate: StrongMatchGate.Evaluation? = nil, edit: Edit? = nil)
        case gateChanged(StrongMatchGate.Evaluation)
        case eligibilityChanged(Bool)
        case verdict(id: UUID, ClassifierVerdict, latencyMilliseconds: Double)
        case failed(id: UUID, AutomaticSwitchDiagnostics.ErrorKind, latencyMilliseconds: Double, retryAfter: Duration? = nil)
        case navigated
        case enter
        /// Enter in un-navigated Search: classify the complete buffer before saving.
        case submitRequested
        case reversed(AutomaticSwitchDiagnostics.ReversalMethod)
        case manualModeChanged(CaptureSession.Mode)
        case tick
        /// A launch-wide Jev slot was freed by a request from an earlier bar session.
        case slotReleased
    }
    enum Effect {
        case classify(id: UUID, text: String)
        case cancel(UUID)
        case enterMode(CaptureSession.Mode)
        case returnToSearch
        case swallowEnter
        case submitCapture(text: String, mode: CaptureSession.Mode)
        case record(AutomaticSwitchDiagnostics.Event)
    }
    private struct Request { let id: UUID; let started: Duration }
    private struct DebugRequest {
        let id: UUID
        let number: Int
        let text: String
        let started: Duration
    }
    private struct Candidate {
        let verdict: ClassifierVerdict
        let latency: Double?
        var prefix: String? = nil
        var cached = false
        /// Set once when a Word-paced answer is handled, even if Search's sources still need to settle.
        var agreementCount: Int? = nil
        var debugRequest: DebugRequest? = nil
    }
    private struct DebugDecision {
        let value: Candidate
        let outcome: AutomaticSwitchDiagnostics.Outcome
        let reason: String
        let agreement: Int
        let requiredAgreement: Int
        let relevance: AutomaticSwitchDebugSnapshot.Relevance
    }
    private var debugRequests: [UUID: DebugRequest] = [:]
    private var debugDecision: DebugDecision?
    private var debugCacheHits = 0
    private var debugSuspension = "suspended"
    private var debugReturnReason: String?
    private struct WordRequest {
        let started: Duration
        /// Normalized text, as sent.
        let text: String
        let sequence: UInt64
        let keyRevision: UInt64
        var valid = true
    }
    let options: AutomaticSwitchOptions
    private let memory: JevLaunchMemory
    private let cacheIdentity: JevLaunchMemory.CacheIdentity
    private let now: () -> Duration
    private var active = false
    private var text = ""
    private var composing = false
    private var eligible = true
    private var suspended = false
    private var mode = CaptureSession.Mode.search
    private var gate = StrongMatchGate.Evaluation(decision: .blocked(.collectionUnavailable), settled: false, allSourcesSettled: false)
    private var request: Request?
    // Invalidated work keeps its launch-wide slot until its terminal callback acknowledges cancellation.
    private var wordRequests: [UUID: WordRequest] = [:]
    private var sequence: UInt64 = 0
    private var newestHandledSequence: UInt64 = 0
    /// The one waiting slot: only the newest normalized text waits for capacity.
    private var waitingText: String?
    /// The normalized text of the last handled answer; sending it again cannot change anything.
    private var answeredText: String?
    private var lastInsertAt: Duration?
    private var requestsSent = 0
    private var isWordPaced: Bool { options.classifier == .jev && options.firing == .wordPaced }
    // A timeout already sampled latency and a cancelled request has none; their later stale rows sample nothing.
    private var unsampledRequests: Set<UUID> = []
    private var due: Duration?
    /// A non-append edit starts a burst. Even appended corrections stay in
    /// that burst until the adaptive pause, holding answers and sends.
    private var deletionPause: Duration?
    private var deletionWasAtEnd = false
    /// The answer's normalized prefix, rather than everything typed by the
    /// time its reply arrived, is the reason for the current switch.
    private var switchPoint: String?
    private var vetoes: [ClassifierVerdict.Label: String] = [:]
    /// Arrival order is already constrained by newestHandledSequence. Keep
    /// earlier answers for confidence, while only the newest may switch.
    private var heldWordAnswers: [Candidate] = []
    private var changedAt: Duration = .zero
    private var candidate: Candidate?
    private var agreementLabel: ClassifierVerdict.Label?
    private var agreementPrefix: String?
    private var agreements = 0
    private var switchedAt: Duration?
    private var enterGraceEnds: Duration?
    private var hadSwitch = false
    private var actedOnText: String?
    var hasActedOnCurrentBuffer: Bool { actedOnText.map { $0.utf8.elementsEqual(text.utf8) } ?? false }
    private var ended = false
    private struct Submission {
        let text: String
        let deadline: Duration
    }
    enum SubmissionOutcome { case undecided, failed, timedOut, blocked }
    private var submission: Submission?
    private(set) var submissionOutcome: SubmissionOutcome?
    var isAwaitingSubmission: Bool { submission != nil }
    private var lateKind: StrongMatchGate.Kind?
    private(set) var lastVerdict = AutomaticSwitchDiagnostics.Label.none
    var lastModeChangeWasAutomatic: Bool { switchedAt != nil }

    /// The earliest time on the `now` clock at which a `.tick` can change
    /// anything: a debounce or pause deadline that can fire, a request's
    /// timeout (1.5 s, or Word-paced's 1.2 s), the 1 s all-sources wait cap, or
    /// the end of the 300 ms Enter grace window. Nil while nothing time-based is pending.
    var nextWakeUp: Duration? {
        guard options.isEnabled, active else { return nil }
        var times: [Duration] = []
        if let submission { times.append(submission.deadline) }
        // A deadline behind an in-flight request waits for that request's event, not for time.
        // A Word-paced pause still fires with both slots busy, to fill the waiting slot.
        if let due, !composing, canClassify, isWordPaced || request == nil {
            times.append(due)
        }
        if let deletionPause, !composing, eligible { times.append(deletionPause) }
        if isWordPaced {
            times += wordRequests.values.filter(\.valid).map { $0.started + requestDeadline }
        } else if let request {
            times.append(request.started + requestDeadline)
        }
        if candidate != nil, options.wait == .allSources, !gate.allSourcesSettled {
            times.append(changedAt + .seconds(1))
        }
        if let enterGraceEnds { times.append(enterGraceEnds) }
        return times.min()
    }

    init(options: AutomaticSwitchOptions, memory: JevLaunchMemory = JevLaunchMemory(),
         cacheIdentity: JevLaunchMemory.CacheIdentity = .current,
         now: @escaping () -> Duration) {
        self.options = options; self.memory = memory; self.cacheIdentity = cacheIdentity; self.now = now
    }

    /// Word-paced request text: trimmed, whitespace runs collapsed to one space, Unicode NFC.
    /// Case is kept. Word counts, duplicate checks and prefix checks all use it.
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    mutating func requestSubmission(gate: StrongMatchGate.Evaluation) -> [Effect] {
        self.gate = gate
        return handle(.submitRequested)
    }

    mutating func handle(_ event: Event) -> [Effect] {
        // Keep the request's correlation available throughout its terminal
        // policy event, including stale/cancelled completions.
        let completedID: UUID? = switch event {
        case .verdict(let id, _, _), .failed(let id, _, _, _): id
        default: nil
        }
        defer { if let completedID { debugRequests[completedID] = nil } }
        // The intent belongs to this exact editor revision, not a prefix or a
        // subsequent edit. Navigation cancels it even when navigationSuspends is off.
        switch event {
        case .bufferChanged(let newText, let composing, _, let edit)
            where !newText.utf8.elementsEqual(text.utf8) || composing || edit != nil:
            submission = nil; submissionOutcome = nil
        case .navigated, .manualModeChanged, .invoked, .dismissed:
            submission = nil; submissionOutcome = nil
        case .eligibilityChanged(false): submission = nil
        default: break
        }
        if let submission, now() >= submission.deadline {
            let effects = timeoutIfDue() ?? []
            return effects + finishSubmission(.timedOut)
        }
        if submission != nil, case .gateChanged(let gate) = event, gate.decision != .allowed {
            self.gate = gate
            return finishSubmission(.blocked)
        }
        let failedSubmission: Bool
        if submission != nil, case .failed(let id, _, _, _) = event {
            failedSubmission = isWordPaced
                ? wordRequests[id].map { $0.valid && $0.text == Self.normalized(text) } == true
                : request?.id == id
        } else { failedSubmission = false }
        let effects = handleEvent(event)
        return failedSubmission && submission != nil ? effects + finishSubmission(.failed) : effects
    }

    private mutating func handleEvent(_ event: Event) -> [Effect] {
        guard options.isEnabled else { return [] }
        switch event {
        case .invoked:
            let effects = cancel()
            active = true; text = ""; composing = false; eligible = true; suspended = false
            mode = .search; candidate = nil; due = nil; agreements = 0; agreementLabel = nil
            waitingText = nil; answeredText = nil; lastInsertAt = nil; requestsSent = 0
            deletionPause = nil; heldWordAnswers = []
            deletionWasAtEnd = false; switchPoint = nil
            vetoes = [:]
            switchedAt = nil; enterGraceEnds = nil; hadSwitch = false; actedOnText = nil; ended = false
            lastVerdict = .none; lateKind = nil
            debugDecision = nil; debugCacheHits = 0; debugReturnReason = nil
            return effects
        case .dismissed(let end):
            let wasActive = active
            active = false; due = nil; candidate = nil; deletionPause = nil
            var effects = cancel()
            if hadSwitch, !ended { effects.append(.record(.ended(end))); ended = true }
            if wasActive { effects.append(.record(.session(requestsSent: requestsSent))) }
            return effects
        default:
            guard active else {
                if isWordPaced {
                    switch event {
                    case .verdict(let id, _, _), .failed(let id, _, _, _):
                        wordRequests[id] = nil; memory.requestFinished(id)
                    default: break
                    }
                }
                return []
            }
        }
        switch event {
        case .bufferChanged(let text, let composing, let newGate, let edit):
            if isWordPaced { return wordPacedBufferChanged(text: text, composing: composing, gate: newGate, edit: edit) }
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
            if isWordPaced, deletionPause != nil {
                guard gate.decision != .allowed else { return [] }
                due = nil; candidate = nil
                return cancel()
            }
            if let late = lateStrongMatchIfNeeded() { return late }
            if isWordPaced, gate.decision != .allowed {
                due = nil; candidate = nil
                return cancel()
            }
            if let candidate { return apply(candidate) + fireIfDue() }
            if isWordPaced, wasBlocked, let cached = applyCachedAnswer(for: Self.normalized(text)) { return cached }
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
            if isWordPaced { return wordPacedCompleted(id: id, verdict: verdict, error: nil, latency: latency) }
            let value = Candidate(verdict: verdict, latency: latency, debugRequest: debugRequests[id])
            guard request?.id == id else { return [staleDiagnostic(id: id, value: value)] }
            if let timeout = timeoutIfDue() { return timeout }
            request = nil
            lastVerdict = diagnosticLabel(verdict.label)
            candidate = value
            return apply(value)
        case .failed(let id, let kind, let latency, let retryAfter):
            if isWordPaced { return wordPacedCompleted(id: id, verdict: failureVerdict, error: kind, latency: latency, retryAfter: retryAfter) }
            guard request?.id == id else {
                return [staleDiagnostic(id: id, value: Candidate(verdict: failureVerdict, latency: latency,
                    debugRequest: debugRequests[id]))]
            }
            if let timeout = timeoutIfDue() { return timeout }
            request = nil; candidate = nil; agreements = 0; agreementLabel = nil
            return [diagnostic(Candidate(verdict: failureVerdict, latency: latency,
                debugRequest: debugRequests[id]), .error, error: kind)]
        case .navigated:
            guard options.navigationSuspends else { return [] }
            debugSuspension = "suspended after navigation"
            suspended = true; candidate = nil; due = nil
            return cancel()
        case .enter:
            guard let switchedAt, options.enterBehavior == .ignoreFor300Milliseconds,
                  now() - switchedAt < .milliseconds(300) else { return [] }
            return [.swallowEnter]
        case .submitRequested:
            if submission != nil { return [.swallowEnter] }
            guard options.classifier == .jev, mode == .search, canClassify,
                  !composing, gate.decision == .allowed,
                  Self.normalized(text).split(separator: " ").count >= 2 else { return [] }
            submissionOutcome = nil
            submission = Submission(text: text, deadline: now() + requestDeadline)
            // Enter flushes the debounce and a correction burst. A partial
            // answer can still be cached, but cannot switch or save this buffer.
            deletionPause = nil; heldWordAnswers = []
            if let candidate, candidate.prefix == nil || candidate.prefix == Self.normalized(text) {
                return [.swallowEnter] + apply(candidate)
            }
            candidate = nil
            if isWordPaced {
                if let cached = applyCachedAnswer(for: Self.normalized(text), preservingAgreement: true) {
                    return [.swallowEnter] + cached
                }
                due = nil
                let effects = sendWordPaced()
                if memory.backoffReason(at: now()) != nil {
                    return [.swallowEnter] + effects + finishSubmission(.failed)
                }
                return [.swallowEnter] + effects
            }
            due = now()
            return [.swallowEnter] + fireIfDue()
        case .reversed(let method):
            guard eligible, !composing, let switchedAt, mode != .search else { return [] }
            debugSuspension = "suspended after reversal"
            if isWordPaced, options.reversalBehavior == .blockModeForText, !text.isEmpty {
                vetoes[mode == .note ? .note : .task] = Self.normalized(text)
            }
            let effects = returnToSearch(recording: .reversed(method: method,
                millisecondsSinceSwitch: milliseconds(now() - switchedAt)))
            if isWordPaced { suspended = options.reversalBehavior == .stopUntilCleared && !text.isEmpty }
            return effects
        case .manualModeChanged(let mode):
            self.mode = mode; switchedAt = nil; enterGraceEnds = nil; candidate = nil; due = nil
            switchPoint = nil
            return cancel()
        case .tick:
            if let enterGraceEnds, now() >= enterGraceEnds { self.enterGraceEnds = nil }
            let timeout = timeoutIfDue() ?? []
            let held = finishDeletionBurstIfDue()
            if let candidate { return timeout + held + apply(candidate) + fireIfDue() }
            return timeout + held + fireIfDue()
        case .slotReleased:
            return isWordPaced ? sendWaiting() : []
        case .invoked, .dismissed: return []
        }
    }

    private mutating func finishSubmission(_ outcome: SubmissionOutcome) -> [Effect] {
        submission = nil; submissionOutcome = outcome
        candidate = nil; due = nil
        return cancel()
    }

    /// Rejected final decisions leave the text available, without replaying
    /// Enter against whatever Search row happens to be selected later.
    private mutating func decisionEffects(_ value: Candidate,
                                         _ outcome: AutomaticSwitchDiagnostics.Outcome) -> [Effect] {
        let effects = [diagnostic(value, outcome)]
        guard submission != nil else { return effects }
        return effects + finishSubmission(.undecided)
    }

    private mutating func lateStrongMatchIfNeeded() -> [Effect]? {
        guard switchedAt != nil, mode != .search,
              case .blocked(.strongMatch(let kind)) = gate.decision, lateKind != kind else { return nil }
        if options.lateStrongMatch == .returnToSearch, !eligible || composing { return [] }
        lateKind = kind
        var effects: [Effect] = [.record(.lateStrongMatch(kind: diagnosticKind(kind),
            outcome: options.lateStrongMatch == .stay ? .stayed : .returnedToSearch))]
        if options.lateStrongMatch == .returnToSearch, eligible, !composing { effects += returnToSearch() }
        return effects
    }

    /// Both reversal routes reset the same session state and end a switch once.
    private mutating func returnToSearch(recording event: AutomaticSwitchDiagnostics.Event? = nil,
                                         end: AutomaticSwitchDiagnostics.End = .reversed) -> [Effect] {
        debugReturnReason = end == .withdrawn ? "returned to Search: switch text removed" : "reversed: returned to Search"
        var effects = cancel()
        switchedAt = nil; enterGraceEnds = nil; mode = .search; candidate = nil; due = nil
        switchPoint = nil
        if isWordPaced { answeredText = nil }
        suspended = options.reversalSuspends && (!isWordPaced || !text.isEmpty); agreements = 0; agreementLabel = nil
        effects.append(.returnToSearch)
        if let event { effects.append(.record(event)) }
        if !ended { effects.append(.record(.ended(end))); ended = true }
        return effects
    }

    private mutating func timeoutIfDue() -> [Effect]? {
        if isWordPaced {
            var effects: [Effect] = []
            for (id, request) in wordRequests.sorted(by: { $0.value.sequence < $1.value.sequence })
                where request.valid && now() - request.started >= requestDeadline {
                wordRequests[id]?.valid = false
                unsampledRequests.insert(id)
                effects += [.cancel(id), diagnostic(Candidate(verdict: failureVerdict,
                    latency: milliseconds(now() - request.started), debugRequest: debugRequests[id]), .timeout)]
            }
            return effects.isEmpty ? nil : effects
        }
        guard let request, now() - request.started >= requestDeadline else { return nil }
        self.request = nil; candidate = nil
        unsampledRequests.insert(request.id)
        return [.cancel(request.id), diagnostic(Candidate(verdict: failureVerdict,
            latency: milliseconds(now() - request.started), debugRequest: debugRequests[request.id]), .timeout)]
    }

    private var firingDelay: Duration {
        switch options.firing {
        case .everyKeystroke: .zero
        case .debounced: .milliseconds(150)
        case .onPause: .milliseconds(500)
        // Word-paced applies only to Jev; with Foundation Models it behaves as debounced.
        case .wordPaced: isWordPaced ? memory.pauseThreshold : .milliseconds(150)
        }
    }
    /// An answer this much later than its send is dropped as a timeout.
    private var requestDeadline: Duration { isWordPaced ? .milliseconds(1200) : .milliseconds(1500) }
    /// An automatic switch stays in its mode: nothing is classified outside Search.
    private var canClassify: Bool { eligible && !suspended && mode == .search }
    private mutating func cancel() -> [Effect] {
        if isWordPaced {
            waitingText = nil; heldWordAnswers = []
            return cancelWordRequests { _ in true }
        }
        guard let request else { return [] }
        self.request = nil
        unsampledRequests.insert(request.id)
        return [.cancel(request.id)]
    }
    private mutating func fireIfDue() -> [Effect] {
        if isWordPaced {
            guard let due, now() >= due else { return [] }
            self.due = nil
            return sendWordPaced()
        }
        guard let due, now() >= due, request == nil, !composing, canClassify else { return [] }
        self.due = nil
        guard gate.decision == .allowed else {
            return [diagnostic(nil, .blocked)]
        }
        let id = UUID(); request = Request(id: id, started: now())
        requestsSent += 1
        debugRequests[id] = DebugRequest(id: id, number: requestsSent, text: text, started: now())
        return [.classify(id: id, text: text)]
    }
    private mutating func apply(_ incoming: Candidate, allowingSwitch: Bool = true) -> [Effect] {
        guard deletionPause == nil else { return [] }
        var value = incoming
        if submission != nil, let prefix = value.prefix, prefix != Self.normalized(text) {
            candidate = nil
            return [diagnostic(value, .stale)]
        }
        if let prefix = value.prefix, !Self.normalized(text).utf8.starts(with: prefix.utf8) {
            candidate = nil
            return [diagnostic(value, .stale)]
        }
        guard !suspended else { candidate = nil; return decisionEffects(value, .suspended) }
        guard eligible, !composing, canClassify else { candidate = nil; return decisionEffects(value, .blocked) }
        guard gate.decision == .allowed else { candidate = nil; agreements = 0; return decisionEffects(value, .blocked) }
        if isWordPaced, let veto = vetoes[value.verdict.label], Self.normalized(text).utf8.starts(with: veto.utf8) {
            candidate = nil; agreements = 0; agreementLabel = nil
            return decisionEffects(value, .blocked)
        }
        if isWordPaced, value.agreementCount == nil {
            let accepts = value.verdict.label != .unsure
                && (value.verdict.probability.map { $0.isFinite && $0 >= options.jevThreshold.rawValue } ?? false)
                && !(value.verdict.label == .task && TaskItem.isMultiline(text))
            if accepts {
                let prefixAgrees = value.prefix.map { prefix in
                    agreementPrefix.map { prefix.utf8.starts(with: $0.utf8) } ?? false
                } ?? false
                if agreementLabel == value.verdict.label, prefixAgrees { agreements += 1 }
                else { agreementLabel = value.verdict.label; agreements = 1 }
                agreementPrefix = value.prefix
            } else { agreements = 0; agreementLabel = nil; agreementPrefix = nil }
            value.agreementCount = agreements
            candidate = value
        }
        // All-source waiting has a hard cap measured from the current edit.
        if options.wait == .allSources, !gate.allSourcesSettled, now() - changedAt < .seconds(1) { return [] }
        if options.wait == .appsAndCollection, !gate.settled { return [] }
        candidate = nil
        if value.verdict.label == .unsure { agreements = 0; return decisionEffects(value, .unsure) }
        if options.classifier == .jev,
           !(value.verdict.probability.map { $0.isFinite && $0 >= options.jevThreshold.rawValue } ?? false) {
            agreements = 0; return decisionEffects(value, .belowThreshold)
        }
        let target: CaptureSession.Mode = switch value.verdict.label {
        case .search, .unsure: .search; case .note: .note; case .task: .task
        }
        if target == .task, TaskItem.isMultiline(text) { agreements = 0; return decisionEffects(value, .multiline) }
        if submission != nil, target == .search { return decisionEffects(value, .blocked) }
        guard target != mode else { agreements = 0; return [diagnostic(value, .blocked)] }
        if !isWordPaced {
            if agreementLabel == value.verdict.label { agreements += 1 }
            else { agreementLabel = value.verdict.label; agreements = 1 }
        }
        let required = requiredAgreements(for: value)
        if (value.agreementCount ?? agreements) < required || !allowingSwitch {
            // Word-paced never resends the same text for a second opinion; the next answer may agree.
            if !isWordPaced { due = now() + max(firingDelay, .milliseconds(150)) }
            return decisionEffects(value, .awaitingAgreement)
        }
        // canClassify held above, so the bar is in Search and the target is Note or Task.
        let switched = now()
        mode = target; switchedAt = switched; hadSwitch = true; actedOnText = text; ended = false
        switchPoint = isWordPaced ? value.prefix ?? Self.normalized(text) : nil
        enterGraceEnds = options.enterBehavior == .ignoreFor300Milliseconds ? switched + .milliseconds(300) : nil
        value.agreementCount = value.agreementCount ?? agreements
        agreements = 0; agreementLabel = nil
        var effects = [diagnostic(value, .switched), .enterMode(target),
                .record(.switched(mode: AutomaticSwitchDiagnostics.Mode(rawValue: target.rawValue)!))]
        if isWordPaced {
            due = nil
            effects += cancel()
        }
        if let submission {
            self.submission = nil
            effects += cancel()
            effects.append(.submitCapture(text: submission.text, mode: target))
        }
        return effects
    }
    private mutating func wordPacedBufferChanged(text newText: String, composing newComposing: Bool,
                                                 gate newGate: StrongMatchGate.Evaluation?, edit: Edit?) -> [Effect] {
        guard !text.utf8.elementsEqual(newText.utf8) || composing != newComposing || edit != nil else { return [] }
        let previousNormalized = Self.normalized(text)
        let replaced: Bool = if case .replacement = edit { true } else { false }
        let appending = !replaced && !composing && !newComposing && newText.utf8.count > text.utf8.count
            && newText.utf8.starts(with: text.utf8)
        if !appending {
            let atEnd: Bool = if case .replacement(let caretAtEnd) = edit { caretAtEnd }
                else { text.utf8.starts(with: newText.utf8) }
            deletionWasAtEnd = deletionPause == nil ? atEnd : deletionWasAtEnd && atEnd
        }
        let time = now()
        // Gaps are measured only between consecutive insertions in this session.
        if appending {
            if let lastInsertAt { memory.recordTypingGap(time - lastInsertAt) }
            lastInsertAt = time
        } else { lastInsertAt = nil }
        // An inserted space or punctuation that follows a word character completes that word.
        let completesWord = appending && newText.last.map(Self.endsWord) == true
            && newText.dropLast().last.map { !Self.endsWord($0) } == true
        if let newGate { gate = newGate }
        text = newText; composing = newComposing; changedAt = time; lateKind = nil
        let current = Self.normalized(text)
        if let agreementPrefix, !current.utf8.starts(with: agreementPrefix.utf8) {
            agreements = 0; agreementLabel = nil; self.agreementPrefix = nil
        }
        vetoes = vetoes.filter { current.utf8.starts(with: $0.value.utf8) }
        if !appending || deletionPause != nil { deletionPause = time + memory.pauseThreshold }
        if deletionPause != nil, let candidate {
            heldWordAnswers.append(candidate); self.candidate = nil
        }
        var effects: [Effect] = []
        if gate.decision != .allowed {
            effects += cancel()
        } else {
            // Appending keeps every request; other edits cancel those whose text was removed.
            let current = Self.normalized(text)
            if let waitingText, !current.utf8.starts(with: waitingText.utf8) { self.waitingText = nil }
            effects += cancelWordRequests { !current.utf8.starts(with: $0.text.utf8) }
        }
        // A held answer is checked against the final prefix at the pause,
        // rather than discarded by each further deletion in the burst.
        if gate.decision != .allowed { candidate = nil; agreements = 0; agreementLabel = nil }
        due = nil
        if text.isEmpty {
            vetoes = [:]; answeredText = nil
            heldWordAnswers = []; candidate = nil; agreements = 0; agreementLabel = nil
            suspended = false
            // An automatically entered mode remains visible until this
            // deletion's pause, including when the last character is removed.
            if switchedAt == nil || mode == .search { deletionPause = nil }
            return effects
        }
        if suspended, !composing { return effects + [diagnostic(nil, .suspended)] }
        guard !composing, canClassify else { return effects }
        if let deletionPause { due = deletionPause; return effects }
        let normalized = Self.normalized(text)
        if !normalized.utf8.elementsEqual(previousNormalized.utf8), let cached = applyCachedAnswer(for: normalized) {
            return effects + cached
        }
        if completesWord { return effects + sendWordPaced() }
        due = time + memory.pauseThreshold
        return effects
    }

    /// Sends the current normalized text, or the waiting text, when every
    /// Word-paced condition holds. With both launch-wide slots busy, the text
    /// takes the single waiting slot, replacing any older waiting text.
    private mutating func sendWordPaced(_ waiting: String? = nil) -> [Effect] {
        guard deletionPause == nil, !composing, canClassify else { return [] }
        let value = waiting ?? Self.normalized(text)
        // One word is never sent, whatever the gate says, so it records nothing.
        guard value.split(separator: " ").count >= 2 else { return [] }
        guard gate.decision == .allowed else { return [diagnostic(nil, .blocked)] }
        guard !(answeredText?.utf8.elementsEqual(value.utf8) ?? false),
              !wordRequests.values.contains(where: { $0.valid && $0.text.utf8.elementsEqual(value.utf8) }) else { return [] }
        if let cached = applyCachedAnswer(for: value) { return cached }
        // Cancellation does not end a physical request. A previous bar's work
        // also keeps this identity until its terminal callback releases it.
        guard !memory.hasRequest(for: value) else { waitingText = value; return [] }
        if let reason = memory.backoffReason(at: now()) {
            waitingText = nil
            return [.record(.verdict(.init(classifier: .jev, wordingVersion: ClassifierWording.jevVersion, label: .none, latencyMilliseconds: nil,
                outcome: .backoff, backoffReason: reason)))]
        }
        guard memory.hasCapacity else { waitingText = value; return [] }
        waitingText = nil
        sequence += 1; requestsSent += 1
        let id = UUID()
        debugRequests[id] = DebugRequest(id: id, number: requestsSent, text: value, started: now())
        wordRequests[id] = WordRequest(started: now(), text: value, sequence: sequence, keyRevision: memory.keyRevision)
        memory.requestStarted(id, text: value)
        return [.classify(id: id, text: value)]
    }

    private mutating func sendWaiting() -> [Effect] {
        guard let waiting = waitingText, memory.hasCapacity else { return [] }
        waitingText = nil
        guard Self.normalized(text).utf8.starts(with: waiting.utf8) else { return [] }
        return sendWordPaced(waiting)
    }

    private mutating func applyCachedAnswer(for text: String, preservingAgreement: Bool = false) -> [Effect]? {
        guard !composing, canClassify, gate.decision == .allowed,
              text.split(separator: " ").count >= 2,
              let verdict = memory.cachedVerdict(for: text, identity: cacheIdentity) else { return nil }
        // Enter reusing a decision already handled in this session is not a
        // second agreeing answer. Preserve its count before updating answeredText.
        let existingAgreement = preservingAgreement && answeredText == text ? agreements : nil
        due = nil; waitingText = nil; answeredText = text
        sequence += 1; newestHandledSequence = sequence
        debugCacheHits += 1
        lastVerdict = diagnosticLabel(verdict.label)
        let value = Candidate(verdict: verdict, latency: nil, prefix: text, cached: true,
                              agreementCount: existingAgreement)
        candidate = value
        return apply(value)
    }

    private mutating func cancelWordRequests(where removed: (WordRequest) -> Bool) -> [Effect] {
        let ids = wordRequests.filter { $0.value.valid && removed($0.value) }
            .sorted { $0.value.sequence < $1.value.sequence }.map(\.key)
        for id in ids { wordRequests[id]?.valid = false; unsampledRequests.insert(id) }
        return ids.map(Effect.cancel)
    }

    private mutating func wordPacedCompleted(id: UUID, verdict: ClassifierVerdict,
                                             error: AutomaticSwitchDiagnostics.ErrorKind?, latency: Double, retryAfter: Duration? = nil) -> [Effect] {
        memory.requestFinished(id)
        let value = Candidate(verdict: verdict, latency: latency, debugRequest: debugRequests[id])
        guard let request = wordRequests.removeValue(forKey: id) else { return sendWaiting() }
        // HTTP failures belong to the launch even when a newer answer already won.
        if request.valid, let error, error != .authentication || request.keyRevision == memory.keyRevision {
            memory.recordFailure(kind: error, retryAfter: retryAfter, at: now())
        }
        guard request.valid else {
            return [staleDiagnostic(id: id, value: value)] + sendWaiting()
        }
        if now() - request.started >= requestDeadline {
            unsampledRequests.insert(id)
            return [diagnostic(Candidate(verdict: failureVerdict,
                latency: milliseconds(now() - request.started), debugRequest: debugRequests[id]), .timeout)] + sendWaiting()
        }
        if let error {
            // A failed earlier prefix must not erase a full-text decision
            // which is waiting for Search's gate to settle.
            if submission != nil, request.text != Self.normalized(text) {
                return [diagnostic(value, .error, error: error)] + sendWaiting()
            }
            newestHandledSequence = max(newestHandledSequence, request.sequence)
            candidate = nil; heldWordAnswers = []; agreements = 0; agreementLabel = nil
            return [diagnostic(value, .error, error: error)] + sendWaiting()
        }
        memory.recordSuccess()
        memory.remember(verdict, for: request.text, identity: cacheIdentity)
        guard request.sequence > newestHandledSequence,
              Self.normalized(text).utf8.starts(with: request.text.utf8) else {
            return [staleDiagnostic(id: id, value: value)] + sendWaiting()
        }
        newestHandledSequence = request.sequence
        lastVerdict = diagnosticLabel(verdict.label)
        answeredText = request.text
        let prefixed = Candidate(verdict: verdict, latency: latency, prefix: request.text, debugRequest: debugRequests[id])
        if deletionPause != nil {
            heldWordAnswers.append(prefixed)
            return sendWaiting()
        }
        candidate = prefixed
        return apply(prefixed) + sendWaiting()
    }

    /// Ends one burst at the pause, rechecking every held prefix. Earlier
    /// answers can establish agreement; only the latest applicable answer
    /// may change the mode, so the bar never briefly visits an older mode.
    private mutating func finishDeletionBurstIfDue() -> [Effect] {
        guard let deletionPause, now() >= deletionPause, !composing, eligible else { return [] }
        self.deletionPause = nil
        let current = Self.normalized(text)
        if deletionWasAtEnd, let switchPoint, current.utf8.count < switchPoint.utf8.count,
           switchPoint.utf8.starts(with: current.utf8), switchedAt != nil, mode != .search {
            let effects = returnToSearch(recording: .withdrawn(mode: .init(rawValue: mode.rawValue)!), end: .withdrawn)
            suspended = false
            return effects
        }
        if let late = lateStrongMatchIfNeeded() { return late }
        let held = heldWordAnswers
        heldWordAnswers = []
        let applicable = held.filter { $0.prefix.map { current.utf8.starts(with: $0.utf8) } ?? true }
        var effects = held.filter { value in
            value.prefix.map { !current.utf8.starts(with: $0.utf8) } ?? false
        }.map { diagnostic($0, .stale) }
        for (index, value) in applicable.enumerated() {
            candidate = value
            effects += apply(value, allowingSwitch: index == applicable.count - 1)
        }
        return effects
    }

    /// Apostrophes and hyphens join a word ("don't", "e-mail") rather than end it.
    private static func endsWord(_ character: Character) -> Bool {
        (character.isWhitespace || character.isPunctuation) && !"'’-‐".contains(character)
    }

    private var failureVerdict: ClassifierVerdict {
        .init(label: .unsure, wordingVersion: options.classifier == .jev ? ClassifierWording.jevVersion : ClassifierWording.version)
    }

    private mutating func staleDiagnostic(id: UUID, value: Candidate) -> Effect {
        diagnostic(Candidate(verdict: value.verdict,
            latency: unsampledRequests.contains(id) ? nil : value.latency, debugRequest: debugRequests[id]), .stale)
    }

    private mutating func diagnostic(_ value: Candidate?, _ outcome: AutomaticSwitchDiagnostics.Outcome,
                            error: AutomaticSwitchDiagnostics.ErrorKind? = nil) -> Effect {
        var row = AutomaticSwitchDiagnostics.Verdict(classifier: options.classifier,
            wordingVersion: options.classifier == .jev ? ClassifierWording.jevVersion : ClassifierWording.version,
            label: value.map { diagnosticLabel($0.verdict.label) } ?? .none,
            latencyMilliseconds: value?.latency, outcome: outcome, errorKind: error,
            wordCount: text.split(whereSeparator: \.isWhitespace).count)
        if let value {
            row.wordingVersion = value.verdict.wordingVersion; row.probability = value.verdict.probability
            row.unsure = value.verdict.label == .unsure; row.cached = value.cached
        }
        if case .blocked(let reason) = gate.decision {
            switch reason {
            case .calculation: row.gateReason = .calculation
            case .oneWord: row.gateReason = .oneWord
            case .collectionUnavailable: row.gateReason = .collectionUnavailable
            case .strongMatch(let kind): row.gateReason = .strongMatch; row.matchedKind = diagnosticKind(kind)
            }
        }
        // Late replies cannot replace the answer responsible for the visible
        // capture, or a newer answer/timeout already shown in Search.
        if let value, outcome != .stale || debugDecision == nil,
           mode == .search || outcome == .switched {
            if outcome != .stale { debugReturnReason = nil }
            debugDecision = DebugDecision(value: value, outcome: outcome,
                reason: debugReason(value, outcome: outcome, error: error),
                agreement: value.agreementCount ?? agreements, requiredAgreement: requiredAgreements(for: value),
                relevance: debugRelevance(value))
        }
        return .record(.verdict(row))
    }
    /// Observing this snapshot neither advances the policy nor touches its cache.
    var debugSnapshot: AutomaticSwitchDebugSnapshot {
        let time = now()
        let latest = debugRequests.values.filter { value in
            if isWordPaced { return wordRequests[value.id]?.valid == true }
            return request?.id == value.id
        }.max { $0.number < $1.number }
        let presentationRequest = latest.map {
            AutomaticSwitchDebugSnapshot.Request(id: $0.id, number: $0.number,
                characters: $0.text.count, elapsedMilliseconds: milliseconds(time - $0.started),
                relevance: debugRelevance(for: $0.text))
        }
        var remaining: Double?
        let state: String
        if !options.isEnabled { state = "automatic switch off" }
        else if !active { state = "idle" }
        else if mode != .search { state = "\(switchedAt == nil ? "manual" : "automatic") \(mode.rawValue.capitalized)" }
        else if composing { state = "waiting for composition" }
        else if suspended { state = debugSuspension }
        else if !eligible { state = "paused for current action" }
        else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { state = "idle" }
        else if case .blocked(let reason) = gate.decision {
            state = switch reason {
            case .calculation: "blocked: Calculation"
            case .oneWord: "not sent: one word"
            case .collectionUnavailable: "blocked: collection unavailable"
            case .strongMatch(let kind): "blocked: strong \(diagnosticKind(kind).rawValue) match"
            }
        } else if isWordPaced, let reason = memory.backoffReason(at: time) {
            state = reason == .keyRejected ? "key rejected: replace API key" : "backoff: \(reason.rawValue)"
            remaining = memory.backoffRemaining(at: time).map(milliseconds)
        } else if let deletionPause {
            state = "holding correction"
            remaining = max(0, milliseconds(deletionPause - time))
        } else if waitingText != nil { state = "queued: waiting for request capacity" }
        else if presentationRequest != nil { state = "requesting" }
        else if candidate != nil { state = "waiting for Search results" }
        else if let due {
            state = "waiting for typing pause"
            remaining = max(0, milliseconds(due - time))
        } else if let submission { state = "Enter: waiting for full-text decision"; remaining = max(0, milliseconds(submission.deadline - time)) }
        else { state = debugReturnReason ?? "idle" }

        let decision: DebugDecision?
        if let candidate {
            decision = DebugDecision(value: candidate, outcome: .blocked,
                reason: deletionPause == nil ? "waiting for Search results" : "holding correction",
                agreement: candidate.agreementCount ?? agreements, requiredAgreement: requiredAgreements(for: candidate),
                relevance: debugRelevance(candidate))
        } else { decision = debugDecision }
        let answer = decision.map { decision in
            let value = decision.value
            return AutomaticSwitchDebugSnapshot.Answer(number: value.debugRequest?.number,
                characters: (value.debugRequest?.text ?? value.prefix)?.count ?? 0,
                label: diagnosticLabel(value.verdict.label), probability: value.verdict.probability,
                latencyMilliseconds: value.latency, cached: value.cached,
                relevance: mode == .search ? debugRelevance(value) : decision.relevance,
                outcome: decision.outcome, reason: decision.reason,
                agreement: decision.agreement, requiredAgreement: decision.requiredAgreement)
        }
        return AutomaticSwitchDebugSnapshot(options: options, state: state, remainingMilliseconds: remaining,
            request: mode == .search && !composing && !suspended && eligible && gate.decision == .allowed && deletionPause == nil ? presentationRequest : nil,
            queued: waitingText != nil, answer: answer, cacheHits: debugCacheHits)
    }

    private func debugRelevance(_ value: Candidate) -> AutomaticSwitchDebugSnapshot.Relevance {
        guard let sent = value.debugRequest?.text ?? value.prefix else { return .stale }
        return debugRelevance(for: sent)
    }

    private func debugRelevance(for sent: String) -> AutomaticSwitchDebugSnapshot.Relevance {
        let current = isWordPaced ? Self.normalized(text) : text
        if current.utf8.elementsEqual(sent.utf8) { return .current }
        return current.utf8.starts(with: sent.utf8) ? .prefix : .stale
    }

    private func requiredAgreements(for value: Candidate) -> Int {
        isWordPaced && (value.verdict.probability ?? 0) < 0.90
            ? max(2, options.agreeingVerdicts.rawValue) : options.agreeingVerdicts.rawValue
    }

    private func debugReason(_ value: Candidate, outcome: AutomaticSwitchDiagnostics.Outcome,
                             error: AutomaticSwitchDiagnostics.ErrorKind?) -> String {
        switch outcome {
        case .switched: "switched · agreement \(value.agreementCount ?? agreements)/\(requiredAgreements(for: value))"
        case .awaitingAgreement: "agreement \(value.agreementCount ?? agreements)/\(requiredAgreements(for: value))"
        case .belowThreshold: "below threshold"
        case .unsure: "unsure: staying in Search"
        case .stale: "ignored: stale"
        case .multiline: "blocked: multiline Task"
        case .suspended: debugSuspension
        case .timeout: "timed out"
        case .error: "error: \(error?.rawValue ?? "other")"
        case .backoff: "backoff"
        case .blocked:
            if case .blocked(let reason) = gate.decision {
                switch reason {
                case .calculation: "blocked: Calculation"
                case .oneWord: "blocked: one word"
                case .collectionUnavailable: "blocked: collection unavailable"
                case .strongMatch(let kind): "blocked: strong \(diagnosticKind(kind).rawValue) match"
                }
            } else if isWordPaced, let veto = vetoes[value.verdict.label], Self.normalized(text).utf8.starts(with: veto.utf8) {
                "blocked: reversal veto"
            } else if value.verdict.label == .search { "staying in Search" }
            else { "blocked by current action" }
        }
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
