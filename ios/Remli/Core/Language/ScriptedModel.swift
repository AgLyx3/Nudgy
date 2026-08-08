import Foundation

/// The deterministic narrator.
///
/// Two jobs, and the second one is the important one:
///
/// 1. It is what runs in the iOS Simulator, where LiteRT-LM cannot do inference at all.
/// 2. It is what `SafetyGuard` swaps in when Gemma writes something it should not have.
///
/// Which means this copy is load-bearing. If the templates read like error messages, then every
/// safety rejection looks like a bug on stage and the honest thing (falling back) becomes the
/// thing nobody wants to do. So these are written to be *good* — calm, cited, and specific — and
/// the demo should read well even if Gemma never loads.
///
/// The templates are built from the same structured `ReminderProposal` the model would have been
/// given, using only verbatim source text. They cannot say anything the record did not.
enum NarrationTemplates {

    static func render(_ request: NarrationRequest) -> String {
        switch request.job {
        case .introduceProposal(let proposal):
            return introduce(proposal, name: request.patientFirstName)
        case .answerFollowUp(let question, let proposal):
            return answer(question, about: proposal)
        case .heardRecap(let recap):
            return heard(recap)
        case .confirmScheduled(let reminder):
            return confirm(reminder, name: request.patientFirstName)
        }
    }

    // MARK: - Introducing a proposal

    private static func introduce(_ proposal: ReminderProposal, name: String?) -> String {
        var sentences: [String] = []

        let opener = proposal.dataOrigin == .liveFHIR || proposal.dataOrigin == .syntheaSynthetic
            ? "I found something in your \(proposal.sourceLabel) record about \(proposal.title)."
            : "\(proposal.title) came in from \(proposal.sourceLabel)."
        sentences.append(opener)

        if let instruction = primaryInstruction(of: proposal) {
            sentences.append("It says: \u{201C}\(instruction)\u{201D}")
        } else if let anyFact = proposal.sourceFacts.first {
            sentences.append("Your record lists it as \u{201C}\(anyFact.verbatim)\u{201D}")
        }

        sentences.append(closingLine(for: proposal))

        return assemble(sentences, greeting: name)
    }

    /// The single most useful verbatim line: the dosage/exercise instruction if there is one.
    private static func primaryInstruction(of proposal: ReminderProposal) -> String? {
        let preferredLabels = ["instruction", "instructions", "how to", "directions"]
        for fact in proposal.sourceFacts {
            let label = fact.label.lowercased()
            if preferredLabels.contains(where: { label.contains($0) }) { return fact.verbatim }
        }
        return nil
    }

    /// What Remli asks for next. Ordered by how much it matters that the user sees it.
    private static func closingLine(for proposal: ReminderProposal) -> String {
        if let concern = proposal.flags.first(where: { $0.severity == .possibleConcern }) {
            let action = concern.suggestedAction ?? "Your care team can tell you which one to follow."
            return "\(concern.detail) \(action)"
        }
        if let declined = proposal.schedulingDeclinedReason {
            return "\(declined.plainLanguage) I have not set anything up for it."
        }
        if proposal.needsTimeOfDay {
            return "It does not say what time of day, so you can pick times that fit your routine."
        }
        if proposal.slots.count == 1, let slot = proposal.slots.first, slot.timeOfDay != nil {
            return "Would you like me to remind you at \(slot.formattedTime)?"
        }
        if proposal.slots.count > 1 {
            let times = proposal.slots.compactMap { $0.timeOfDay == nil ? nil : $0.formattedTime }
            if times.count == proposal.slots.count {
                return "Would you like me to remind you at \(joined(times))?"
            }
            return "Would you like me to set \(proposal.slots.count) reminders for it?"
        }
        return "Would you like me to remind you about it?"
    }

    // MARK: - Answering a follow-up

    /// A keyword router, not an understander.
    ///
    /// It cannot answer an arbitrary question, and it does not pretend to — every branch either
    /// quotes the record or says the record is silent. That is a worse conversation than Gemma
    /// gives and a perfectly honest one.
    private static func answer(_ question: String, about proposal: ReminderProposal) -> String {
        let q = question.lowercased()

        if contains(q, ["what time", "when should", "when do", "when will", "time of day", "hour", "morning", "night", "evening"]) {
            if proposal.needsTimeOfDay {
                return "Your record says how often, but not what time of day. You can pick times that fit your routine, and I will label those as your choice rather than your chart's."
            }
            let times = proposal.slots.map { $0.formattedTime }
            return "Right now this one is set for \(joined(times)). You can change that any time."
        }

        if contains(q, ["food", "eat", "meal", "stomach", "water", "drink", "empty"]) {
            if let fact = factMentioning(["food", "meal", "stomach", "water"], in: proposal) {
                return "Your record says: \u{201C}\(fact.verbatim)\u{201D} That is from \(fact.citation.sourceLabel)."
            }
            return "Your record does not say anything about food for this one. Your pharmacist or care team can tell you more."
        }

        if contains(q, ["how often", "frequency", "how many times", "how much"]) {
            if let fact = factMentioning(["daily", "times", "week", "every", "how often"], in: proposal) {
                return "Your record says: \u{201C}\(fact.verbatim)\u{201D}"
            }
            return "Your record does not say how often for this one, which is why it is waiting for your review."
        }

        if contains(q, ["where", "who said", "source", "why am i", "why do i", "came from", "which doctor", "citation"]) {
            let origin = proposal.dataOrigin.shortLabel.lowercased()
            var line = "This came from your \(proposal.sourceLabel) records (\(origin))."
            if let fact = proposal.sourceFacts.first {
                line += " The exact text is \u{201C}\(fact.verbatim)\u{201D}"
            }
            return line
        }

        // Fall through: show what there is, and be clear that it is all there is.
        let facts = proposal.sourceFacts.prefix(2)
            .map { "\($0.label.lowercased()) \u{201C}\($0.verbatim)\u{201D}" }
        if facts.isEmpty {
            return "I do not have anything else in your record about \(proposal.title). Your care team can tell you more."
        }
        return "Here is what your record has on \(proposal.title): \(joined(Array(facts))). That is everything it says, so anything beyond it is a question for your care team."
    }

    private static func factMentioning(_ keywords: [String], in proposal: ReminderProposal) -> SourceFact? {
        for fact in proposal.sourceFacts {
            let haystack = (fact.label + " " + fact.verbatim).lowercased()
            if keywords.contains(where: { haystack.contains($0) }) { return fact }
        }
        return nil
    }

    // MARK: - "I heard"

    private static func heard(_ recap: HeardRecap) -> String {
        guard !recap.understoodPoints.isEmpty else {
            return "I did not catch anything I could act on there. Could you say that again?"
        }
        var text = "Here is what I heard: \(recap.understoodPoints.joined(separator: "; "))."
        if let question = recap.openQuestion {
            text += " One thing I am not sure about: \(question)"
        } else {
            text += " Tell me if I got any of that wrong."
        }
        return text
    }

    // MARK: - Confirming

    private static func confirm(_ reminder: ApprovedReminder, name: String?) -> String {
        let times = TimeOfDayFormatter.list(reminder.times)
        let sentences = [
            "\(reminder.title) is set for \(times).",
            "I will nudge you here on this phone, and you can change or turn it off any time."
        ]
        return assemble(sentences, greeting: name, opener: "Okay")
    }

    // MARK: - Helpers

    private static func assemble(_ sentences: [String], greeting: String?, opener: String? = nil) -> String {
        var parts = sentences.filter { !$0.isEmpty }
        if let opener, !parts.isEmpty {
            // Left as-is rather than lower-cased: the first word is usually a medication name,
            // and "Okay — metformin 500 mg is set" quietly misspells the user's prescription.
            let prefix = greeting.map { "\(opener), \($0) —" } ?? "\(opener) —"
            parts[0] = "\(prefix) \(parts[0])"
        }
        return parts.joined(separator: " ")
    }

    private static func joined(_ values: [String]) -> String {
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default: return values.dropLast().joined(separator: ", ") + ", and " + (values.last ?? "")
        }
    }

    private static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

/// `RemliLanguageModel` backed entirely by `NarrationTemplates`.
///
/// Reports `.deterministicTemplate` for every single result, always. There is no code path in
/// this type that can claim Gemma wrote something.
final class ScriptedModel: RemliLanguageModel {

    let isOnDevice = false
    let displayName = "Scripted narration"
    /// Settable so `LanguageModelProvider` can keep the explanation current as the reason for
    /// falling back changes (weights downloading → weights ready → engine failed).
    var availabilityNote: String?

    /// Per-word delay used by `narrateStream`, so the simulator demo still has the calm typing
    /// rhythm the design doc asks for. Purely cosmetic; set to 0 in tests.
    var typingDelayNanoseconds: UInt64

    init(availabilityNote: String? = nil, typingDelayNanoseconds: UInt64 = 28_000_000) {
        self.availabilityNote = availabilityNote
        self.typingDelayNanoseconds = typingDelayNanoseconds
    }

    func prepare() async throws {
        // Nothing to load. This is the whole point of it.
    }

    func narrate(_ request: NarrationRequest) async throws -> NarrationResult {
        .template(text: NarrationTemplates.render(request))
    }

    /// Streams word by word. No `SafetyGuard` pass is needed or claimed: this text was not
    /// generated, it was composed from verbatim record fields by code in this repository.
    func narrateStream(_ request: NarrationRequest) -> AsyncThrowingStream<NarrationEvent, Error> {
        let text = NarrationTemplates.render(request)
        let delay = typingDelayNanoseconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                var isFirst = true
                for word in text.split(separator: " ", omittingEmptySubsequences: true) {
                    if Task.isCancelled { break }
                    continuation.yield(.delta(isFirst ? String(word) : " " + word))
                    isFirst = false
                    if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
                }
                continuation.yield(.completed(.template(text: text)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
