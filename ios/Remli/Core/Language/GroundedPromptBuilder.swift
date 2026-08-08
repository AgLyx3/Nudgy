import Foundation

/// A fully assembled prompt plus everything needed to judge and, if necessary, replace its answer.
struct GroundedPrompt {
    let systemMessage: String
    let userMessage: String
    /// The exact facts the model was shown. `SafetyGuard` checks the answer against this and
    /// nothing else, so builder and guard cannot drift apart.
    let grounding: GroundingContext
    /// The deterministic sentence that runs if the model is unavailable or fails review.
    let fallbackText: String
    let maxSentences: Int
}

/// Assembles every prompt Remli ever sends to a language model.
///
/// ## Why this type exists at all
///
/// The temptation in a hackathon is `"Tell the user about \(medication)"` at the call site. That
/// works, and it makes the grounding guarantee unauditable — nobody can answer "what could the
/// model see?" without reading every view model. Here, the answer is one file.
///
/// Three properties this file is responsible for:
///
/// - **Only one proposal is ever in context.** Never the vault, never the medication list, never
///   the conversation history. If the model has no other medications in front of it, it cannot
///   confuse two of them.
/// - **Facts are labelled fields, not prose.** A free-text blob invites the model to continue the
///   blob. `Verbatim instruction: "Take 1 tablet by mouth twice daily with meals."` invites it to
///   quote a field.
/// - **Gaps are stated explicitly.** The most important lines in most of these prompts are the
///   `Not in the record:` ones. A model that is never told what is missing will fill it in.
enum GroundedPromptBuilder {

    static let systemMessage = """
    You are Remli, a calm health assistant that runs entirely on this person's phone.

    Everything clinical has already been decided before you are asked anything. Your only job is \
    to phrase what is in the CONTEXT block warmly and briefly. Follow these rules exactly.

    1. You may only restate facts that appear in the CONTEXT block. If the CONTEXT does not \
    contain something, say plainly that it is not in the record.
    2. Never give medical advice, dosing guidance, diagnosis, or triage. Never tell the person \
    what to take, when to take it, whether to change a dose, or whether something is safe.
    3. Never invent a number, strength, dose, frequency, duration, or clock time. Only use \
    numbers that already appear in the CONTEXT block.
    4. Attribute clinical facts: say "Your record says...", "Your chart lists...". Quote the \
    verbatim instruction exactly, in quotation marks, when you use it.
    5. Anything about timing that the record did not state is Remli's convenience suggestion, not \
    a clinical one. Offer it as a question, never as an instruction.
    6. Keep every reply to 1 to 3 short, calm sentences. No lists, no headings, no emoji, no \
    markdown.
    7. If the person asks something the CONTEXT does not answer, say so and suggest their care \
    team or pharmacist can tell them more.

    The examples below are illustrations of tone only. Never copy their facts, names, numbers, or \
    times into a real reply.

    EXAMPLE A - the record gives a frequency but no time of day.
    Good: "Your chart says this is taken once daily. It does not say what time of day. Mornings \
    look open in your calendar, so I can remind you then if that matches your routine."
    Bad: "You should take this medication in the morning."

    EXAMPLE B - the record has no food instruction.
    Good: "Your record does not say anything about food for this one. Your pharmacist can tell \
    you more."
    Bad: "Take it with food so it does not upset your stomach."

    EXAMPLE C - two records disagree.
    Good: "Two of your records describe this differently, so it may be worth asking your care \
    team which one to follow."
    Bad: "Follow the newer instruction and ignore the older one."
    """

    // MARK: - Entry point

    static func build(for request: NarrationRequest) -> GroundedPrompt {
        var grounding = GroundingContext()
        let body: String
        let task: String

        switch request.job {
        case .introduceProposal(let proposal):
            body = proposalFields(proposal, grounding: &grounding)
            task = """
            Introduce this reminder to the person in 1 to 3 sentences. Say where it came from, \
            restate what the record says, and if a detail is missing say that it is missing. If \
            there is a time to choose, ask whether they would like you to remind them. Do not \
            repeat the whole card - the details are already on screen next to your words.
            """

        case .answerFollowUp(let question, let proposal):
            body = proposalFields(proposal, grounding: &grounding)
            // The person's own words are grounding for restatement. Echoing a number they said is
            // not a hallucination; it is the only way to answer "is 850 mg right?" honestly with
            // "your record does not mention 850 mg". Rules 1 and 3 still apply to the answer.
            grounding.add("The person asked: \(question)")
            task = """
            The person asked: "\(question)"

            Answer in 1 to 3 sentences using only the CONTEXT above. If the CONTEXT does not \
            answer the question, say that it is not in the record and that their care team or \
            pharmacist can tell them more.
            """

        case .heardRecap(let recap):
            body = recapFields(recap, grounding: &grounding)
            task = """
            Give a short "here is what I heard" recap in 1 to 2 sentences using only the points \
            above, then invite them to correct you. Do not add anything they did not say.
            """

        case .confirmScheduled(let reminder):
            body = scheduledFields(reminder, grounding: &grounding)
            task = """
            Confirm warmly in 1 to 2 sentences that this reminder is now set, mentioning the \
            times exactly as written above, and remind them they can change or turn it off any \
            time.
            """
        }

        if let name = request.patientFirstName, !name.isEmpty {
            grounding.add("The person's first name is \(name)")
        }

        let userMessage = """
        CONTEXT
        \(body)
        END CONTEXT

        TASK
        \(task)
        """

        return GroundedPrompt(
            systemMessage: systemMessage,
            userMessage: userMessage,
            grounding: grounding,
            fallbackText: NarrationTemplates.render(request),
            maxSentences: request.maxSentences
        )
    }

    // MARK: - Field blocks

    /// The proposal as labelled fields.
    ///
    /// Every line emitted here is also added to the grounding corpus, which is what makes the
    /// guard's number rule workable: counts, slot labels and formatted times are *stated*, so the
    /// model can say "the first of two reminders" without inventing anything, and `SafetyGuard`
    /// needs no surface-form exemptions to let it through.
    private static func proposalFields(
        _ proposal: ReminderProposal,
        grounding: inout GroundingContext
    ) -> String {
        var lines: [String] = []

        func emit(_ line: String) {
            lines.append(line)
            grounding.add(line)
        }

        emit("Kind: \(proposal.kind.noun)")
        emit("Name: \(proposal.title)")
        if let subtitle = proposal.subtitle, !subtitle.isEmpty {
            emit("Detail: \(subtitle)")
        }
        emit("Source organization: \(proposal.sourceLabel)")
        emit("Where this data came from: \(proposal.dataOrigin.shortLabel)")
        emit("Rule category: \(proposal.primaryProvenance.badgeText)")

        switch proposal.primaryProvenance {
        case .patternNoticed(let basis):
            emit("Pattern Remli noticed: \(basis)")
        case .convenienceSuggestion(let basis):
            emit("Remli's convenience suggestion is based on: \(basis)")
        case .needsReview(let reason):
            emit("Needs review because: \(reason.plainLanguage)")
        case .fromYourRecord(let citation):
            emit("Recorded by: \(citation.sourceLabel) (\(citation.resourceType))")
        }

        for fact in proposal.sourceFacts {
            emit("\(fact.label) (verbatim from \(fact.citation.sourceLabel)): \"\(fact.verbatim)\"")
        }

        // Counts and slot labels, stated as facts so they are grounded rather than exempted.
        emit("Number of reminder times per day: \(proposal.slots.count)")
        if proposal.slots.count > 0 {
            grounding.add("\(proposal.slots.count) times a day")
            grounding.add("\(proposal.slots.count) times daily")
            grounding.add("\(proposal.slots.count) reminders")
        }
        for (index, slot) in proposal.slots.enumerated() {
            let time = slot.timeOfDay == nil ? "not stated in the record" : slot.formattedTime
            emit("Reminder \(index + 1) of \(proposal.slots.count) - \(slot.label): \(time) [\(slot.provenance.badgeText)]")
        }

        if proposal.needsTimeOfDay {
            emit("Not in the record: what time of day to do this.")
        }
        if let declined = proposal.schedulingDeclinedReason {
            emit("Remli is not proposing a schedule because: \(declined.plainLanguage)")
        }

        for flag in proposal.flags {
            let severity = flag.severity == .possibleConcern ? "Possible concern" : "Note"
            emit("\(severity): \(flag.title) - \(flag.detail)")
            if let action = flag.suggestedAction {
                emit("What the person can do: \(action)")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func recapFields(_ recap: HeardRecap, grounding: inout GroundingContext) -> String {
        var lines: [String] = []

        func emit(_ line: String) {
            lines.append(line)
            grounding.add(line)
        }

        emit("The person said: \"\(recap.userUtterance)\"")
        if recap.understoodPoints.isEmpty {
            emit("Remli did not extract any points from that.")
        }
        for (index, point) in recap.understoodPoints.enumerated() {
            emit("Point \(index + 1) of \(recap.understoodPoints.count): \(point)")
        }
        if let question = recap.openQuestion {
            emit("Still unclear: \(question)")
        }
        return lines.joined(separator: "\n")
    }

    private static func scheduledFields(
        _ reminder: ApprovedReminder,
        grounding: inout GroundingContext
    ) -> String {
        var lines: [String] = []

        func emit(_ line: String) {
            lines.append(line)
            grounding.add(line)
        }

        emit("Kind: \(reminder.kind.noun)")
        emit("Name: \(reminder.title)")
        emit("Notification text: \(reminder.body)")
        emit("Source organization: \(reminder.sourceLabel)")
        emit("Where this data came from: \(reminder.dataOrigin.shortLabel)")
        emit("Number of reminder times per day: \(reminder.times.count)")
        grounding.add("\(reminder.times.count) times a day")
        for (index, time) in reminder.times.enumerated() {
            emit("Reminder \(index + 1) of \(reminder.times.count): \(TimeOfDayFormatter.string(from: time))")
        }
        for fact in reminder.sourceFacts {
            emit("\(fact.label) (verbatim from \(fact.citation.sourceLabel)): \"\(fact.verbatim)\"")
        }
        emit("The person approved this themselves.")
        return lines.joined(separator: "\n")
    }
}

/// Shared clock formatting so the prompt, the template, and the timeline all print a time the same
/// way. If they disagreed, `SafetyGuard` would reject correct output for saying "8 AM" when the
/// context said "8:00 AM".
enum TimeOfDayFormatter {
    static func string(from components: DateComponents) -> String {
        guard let hour = components.hour, let minute = components.minute else {
            return "time not set"
        }
        var calendarComponents = DateComponents()
        calendarComponents.year = 2000
        calendarComponents.month = 1
        calendarComponents.day = 1
        calendarComponents.hour = hour
        calendarComponents.minute = minute
        guard let date = Calendar.current.date(from: calendarComponents) else { return "time not set" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func list(_ times: [DateComponents]) -> String {
        let strings = times.map { string(from: $0) }
        switch strings.count {
        case 0: return "no times yet"
        case 1: return strings[0]
        case 2: return "\(strings[0]) and \(strings[1])"
        default:
            return strings.dropLast().joined(separator: ", ") + ", and " + (strings.last ?? "")
        }
    }
}
