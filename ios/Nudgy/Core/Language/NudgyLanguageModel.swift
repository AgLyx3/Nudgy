import Foundation

// MARK: - The jobs the language layer actually has

/// A recap of what the user just said, already reduced to points by the deterministic layer.
///
/// The model is *not* asked to interpret speech. `understoodPoints` are produced upstream; the
/// model only phrases them warmly. That keeps "I heard" summaries from quietly inventing intent.
struct HeardRecap: Hashable {
    var userUtterance: String
    var understoodPoints: [String]
    var openQuestion: String?

    init(userUtterance: String, understoodPoints: [String], openQuestion: String? = nil) {
        self.userUtterance = userUtterance
        self.understoodPoints = understoodPoints
        self.openQuestion = openQuestion
    }
}

/// The four things Nudgy ever asks a language model to write.
///
/// Deliberately closed. There is no `case freeform(String)` — a free-text escape hatch is how a
/// grounded system stops being grounded, because the call site would then own the prompt and
/// `GroundedPromptBuilder` would no longer see every request.
enum NarrationJob: Hashable {
    /// "Here is a reminder I found." The card renders the facts; this is the sentence around it.
    case introduceProposal(ReminderProposal)
    /// The user asked something about one specific proposal. Only that proposal is in context.
    case answerFollowUp(question: String, proposal: ReminderProposal)
    /// The periodic "I heard" summary the design doc asks for.
    case heardRecap(HeardRecap)
    /// "That's set." Confirmation after the user approved and the notification was scheduled.
    case confirmScheduled(ApprovedReminder)
}

/// One narration ask, complete. Everything the prompt builder needs is here; nothing else is read.
struct NarrationRequest: Hashable {
    var job: NarrationJob
    /// Used only for warmth ("Okay, Marcus —"). Never treated as a clinical fact.
    var patientFirstName: String?
    /// The design doc asks for short assistant turns. Enforced twice: asked for in the prompt,
    /// and trimmed by `SafetyGuard` if the model ignores it.
    var maxSentences: Int

    init(job: NarrationJob, patientFirstName: String? = nil, maxSentences: Int = 3) {
        self.job = job
        self.patientFirstName = patientFirstName
        self.maxSentences = max(1, maxSentences)
    }

    static func introduce(_ proposal: ReminderProposal, patientFirstName: String? = nil) -> NarrationRequest {
        NarrationRequest(job: .introduceProposal(proposal), patientFirstName: patientFirstName)
    }

    static func followUp(
        _ question: String,
        about proposal: ReminderProposal,
        patientFirstName: String? = nil
    ) -> NarrationRequest {
        NarrationRequest(job: .answerFollowUp(question: question, proposal: proposal),
                         patientFirstName: patientFirstName)
    }

    static func recap(_ recap: HeardRecap, patientFirstName: String? = nil) -> NarrationRequest {
        NarrationRequest(job: .heardRecap(recap), patientFirstName: patientFirstName)
    }

    static func confirm(_ reminder: ApprovedReminder, patientFirstName: String? = nil) -> NarrationRequest {
        NarrationRequest(job: .confirmScheduled(reminder), patientFirstName: patientFirstName)
    }
}

// MARK: - Grounding

/// The exact set of strings the model is permitted to restate.
///
/// This type is the contract between `GroundedPromptBuilder` (which fills it) and `SafetyGuard`
/// (which enforces it). If a number, a clock time, or a time-of-day anchor is not somewhere in
/// `corpus`, the model was not told it, so saying it is a fabrication — regardless of how
/// plausible it sounds.
///
/// Note what is *not* in here: the vault. Only the single proposal under discussion is ever
/// grounded, so a model that starts free-associating about other medications has nothing to
/// anchor to and gets rejected.
struct GroundingContext: Hashable {
    private(set) var facts: [String]

    init(facts: [String] = []) {
        self.facts = facts.compactMap { GroundingContext.clean($0) }
    }

    mutating func add(_ fact: String?) {
        guard let cleaned = GroundingContext.clean(fact) else { return }
        facts.append(cleaned)
    }

    mutating func add(contentsOf newFacts: [String]) {
        for fact in newFacts { add(fact) }
    }

    /// Everything the model may restate, one fact per line.
    var corpus: String { facts.joined(separator: "\n") }

    var isEmpty: Bool { facts.isEmpty }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Results

/// What the language layer produced, and who really produced it.
///
/// `source` is not decoration. It is rendered in the timeline so a demo audience can never be
/// misled about whether Gemma actually wrote a sentence, and so a SafetyGuard rejection is
/// visible rather than silent.
struct NarrationResult {
    let text: String
    let source: NarrationSource
    /// Nil when no model output existed to review (pure template path).
    let verdict: SafetyVerdict?

    /// True when SafetyGuard changed what the user sees — either by rejecting model output
    /// outright or by trimming an over-long reply.
    var safetyDidIntervene: Bool {
        guard let verdict else { return false }
        return verdict.decision == .rejected || verdict.didTrim
    }

    /// True when the words on screen came out of the neural model.
    var isModelAuthored: Bool { source == .gemmaOnDevice }

    static func model(text: String, verdict: SafetyVerdict) -> NarrationResult {
        NarrationResult(text: text, source: .gemmaOnDevice, verdict: verdict)
    }

    /// The deterministic template. Used when there is no model, or when SafetyGuard said no.
    static func template(text: String, verdict: SafetyVerdict? = nil) -> NarrationResult {
        NarrationResult(text: text, source: .deterministicTemplate, verdict: verdict)
    }
}

/// Streaming protocol between the language layer and the timeline.
///
/// **Contract, and the reason streaming is safe here:** `delta` is a *preview* only. The UI may
/// render deltas for the calm typing feel, but it must not commit anything to the timeline until
/// `completed` arrives, and `completed.text` is authoritative — it may differ from the
/// concatenated deltas (trimmed, or replaced wholesale by the template). `retracted` is an early
/// signal that the preview must be cleared; a `completed` always follows it.
enum NarrationEvent {
    case delta(String)
    case retracted(SafetyVerdict)
    case completed(NarrationResult)
}

/// Everything that can go wrong below the provider. Typed so `LanguageModelProvider` can decide
/// whether to fall back permanently (no package, no file) or just for this turn (generation blew up).
enum LanguageModelError: Error, LocalizedError, Equatable {
    /// The LiteRT-LM Swift package is not linked into the target.
    case runtimeUnavailable(String)
    /// The `.litertlm` weights are not on disk yet.
    case modelFileMissing
    /// `Engine.initialize()` failed on every backend we tried.
    case engineInitializationFailed(String)
    /// Generation started and then failed.
    case generationFailed(String)
    /// This environment structurally cannot run inference (the iOS Simulator).
    case unsupportedEnvironment(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let detail):
            return "The on-device model runtime is not available: \(detail)"
        case .modelFileMissing:
            return "The Gemma model file is not on this device yet."
        case .engineInitializationFailed(let detail):
            return "Gemma could not start: \(detail)"
        case .generationFailed(let detail):
            return "Gemma stopped mid-sentence: \(detail)"
        case .unsupportedEnvironment(let detail):
            return detail
        case .cancelled:
            return "Narration was cancelled."
        }
    }

    /// True when retrying with the same model has any chance of working. Drives whether the
    /// provider downgrades to `ScriptedModel` permanently or just for this turn.
    var isPermanent: Bool {
        switch self {
        case .runtimeUnavailable, .modelFileMissing, .unsupportedEnvironment, .engineInitializationFailed:
            return true
        case .generationFailed, .cancelled:
            return false
        }
    }
}

// MARK: - The protocol

/// The seam between the conversation UI and whatever is writing the sentences.
///
/// Two implementations exist and both are first class: `LiteRTGemmaModel` on a physical iPhone,
/// `ScriptedModel` everywhere else. The app is fully usable through either, because the clinical
/// content never came from the model in the first place.
protocol NudgyLanguageModel: AnyObject {
    /// True only when an actual neural language model is producing the words on this device.
    /// `ScriptedModel` returns false — it runs locally too, but calling template rendering
    /// "on-device AI" is the kind of overstatement this app is built to avoid.
    var isOnDevice: Bool { get }

    /// e.g. "Gemma 4 E2B · on device". Shown in the status strip and Settings.
    var displayName: String { get }

    /// One honest sentence about why this implementation is the one running, if there is
    /// anything to explain. Nil when nothing needs explaining.
    var availabilityNote: String? { get }

    /// Expensive setup. Called off the launch path; safe to call repeatedly.
    func prepare() async throws

    func narrate(_ request: NarrationRequest) async throws -> NarrationResult

    /// Streaming variant. See `NarrationEvent` for the commit contract.
    func narrateStream(_ request: NarrationRequest) -> AsyncThrowingStream<NarrationEvent, Error>
}

extension NudgyLanguageModel {
    var availabilityNote: String? { nil }

    /// Default streaming: run the non-streaming path and emit it as one delta.
    /// Implementations with real token streams override this.
    func narrateStream(_ request: NarrationRequest) -> AsyncThrowingStream<NarrationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await self.narrate(request)
                    continuation.yield(.delta(result.text))
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - The shared pipeline

/// Prompt assembly → generation → SafetyGuard → result.
///
/// Lives here, outside any `#if canImport(LiteRTLM)` block, on purpose: this is the part that
/// decides what reaches the user, so it must compile, be readable, and be testable on a machine
/// that has never seen the LiteRT-LM package. `LiteRTGemmaModel` supplies only the raw-token
/// closure; it does not get to skip the guard, because it never sees the guard.
enum NarrationPipeline {

    /// One-shot generation.
    ///
    /// `generate` returns raw model text. Any error it throws is *not* propagated: a language
    /// failure must never take down a health reminder, so it degrades to the template. Callers
    /// that need the error for provider-level downgrade decisions should use `runReportingErrors`.
    static func run(
        request: NarrationRequest,
        generate: (GroundedPrompt) async throws -> String
    ) async -> NarrationResult {
        let prompt = GroundedPromptBuilder.build(for: request)
        do {
            let raw = try await generate(prompt)
            return finish(raw: raw, prompt: prompt)
        } catch {
            return .template(text: prompt.fallbackText)
        }
    }

    /// Same as `run`, but rethrows generation failures so the provider can decide to downgrade.
    static func runReportingErrors(
        request: NarrationRequest,
        generate: (GroundedPrompt) async throws -> String
    ) async throws -> NarrationResult {
        let prompt = GroundedPromptBuilder.build(for: request)
        let raw = try await generate(prompt)
        return finish(raw: raw, prompt: prompt)
    }

    /// Applies SafetyGuard to finished text and picks the result.
    static func finish(raw: String, prompt: GroundedPrompt) -> NarrationResult {
        let verdict = SafetyGuard.review(raw, against: prompt.grounding, maxSentences: prompt.maxSentences)
        switch verdict.decision {
        case .allowed:
            return .model(text: verdict.sanitizedText, verdict: verdict)
        case .rejected:
            return .template(text: prompt.fallbackText, verdict: verdict)
        }
    }

    /// Streaming generation with buffer-then-validate semantics.
    ///
    /// Two layers of checking, for two different reasons:
    ///
    /// 1. **Incremental tripwire** on the accumulating buffer. Catches the unambiguous phrase
    ///    failures ("you should take…") the moment they are complete, so the user does not watch
    ///    unsafe copy type itself out. It emits `.retracted` and stops the generation early.
    /// 2. **Full review** of the complete text before `.completed`. This is the authoritative
    ///    check, because the number-grounding rule genuinely cannot run on a prefix: "50" is a
    ///    perfectly grounded token right up until the model finishes typing "500".
    static func stream(
        request: NarrationRequest,
        tokens: @escaping (GroundedPrompt) -> AsyncThrowingStream<String, Error>
    ) -> AsyncThrowingStream<NarrationEvent, Error> {
        let prompt = GroundedPromptBuilder.build(for: request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = ""
                var tripwire: SafetyVerdict?
                var generationFailed = false

                do {
                    for try await chunk in tokens(prompt) {
                        if Task.isCancelled { break }
                        buffer += chunk
                        if let verdict = SafetyGuard.partialTripwire(buffer, against: prompt.grounding) {
                            tripwire = verdict
                            continuation.yield(.retracted(verdict))
                            break
                        }
                        continuation.yield(.delta(chunk))
                    }
                } catch {
                    generationFailed = true
                }

                if generationFailed && buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Nothing usable arrived. Fall back without pretending a review happened.
                    continuation.yield(.completed(.template(text: prompt.fallbackText)))
                    continuation.finish()
                    return
                }

                let verdict = tripwire ?? SafetyGuard.review(
                    buffer,
                    against: prompt.grounding,
                    maxSentences: prompt.maxSentences
                )

                switch verdict.decision {
                case .allowed:
                    // May differ from the deltas if it was trimmed. `completed` wins.
                    continuation.yield(.completed(.model(text: verdict.sanitizedText, verdict: verdict)))
                case .rejected:
                    if tripwire == nil { continuation.yield(.retracted(verdict)) }
                    continuation.yield(.completed(.template(text: prompt.fallbackText, verdict: verdict)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
