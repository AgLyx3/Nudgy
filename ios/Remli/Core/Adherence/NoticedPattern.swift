import Foundation

/// The three things Remli is allowed to notice.
///
/// Note what is absent: there is no `.nonAdherent`, no `.decliningCompliance`, no `.riskScore`.
/// The kinds are named after *reminder problems*, because reminder problems are the only problems
/// this app is equipped to see. Every one of them opens a question about the reminder; none of
/// them concludes anything about the person.
enum PatternKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Repeated snoozes or consistently late Done taps clustered on one slot. The time is probably
    /// wrong. The safest and most useful of the three: the evidence is a deliberate tap, the
    /// conclusion is about a clock, and the fix is one the user can accept in a second.
    case timeFit
    /// Repeated `.noResponse` or `.dismissedAsSkipped` for one reminder. The weakest evidence in
    /// the app and the most dangerous copy. Gated off by default — see `PatternDetector.Options`.
    case silence
    /// A dense block of reminders inside a short window that mostly goes unanswered. A
    /// notification-management observation, explicitly a UX matter and not a clinical one.
    case clusterFatigue

    /// The generic opener for this kind, with no specifics filled in.
    ///
    /// The canonical copy lives here so the whole voice of the proactive layer can be reviewed in
    /// one place — including by someone who does not read Swift. `NoticedPattern.question` weaves
    /// the honest counts into it.
    ///
    /// Every one of these is a question. None of them is a correction, and none of them describes
    /// what the user did with their medication.
    var question: String {
        switch self {
        case .timeFit:
            return "This reminder keeps getting pushed back. Would a different time suit you better?"
        case .silence:
            return "This one hasn't been coming back to me as done for a while. "
                + "That might just mean you don't tap the button — I honestly can't tell from here. "
                + "Can I ask which it is?"
        case .clusterFatigue:
            return "Several reminders land within about half an hour of each other. "
                + "Would one nudge instead of three be easier?"
        }
    }

    /// The canonical answers for this kind.
    ///
    /// `NoticedPattern.answerOptions` specializes these with a concrete time when it has one.
    ///
    /// **The first option for `.silence` is load-bearing.** "I've been keeping up with it — I just
    /// don't tap" has to be the first thing on screen, because otherwise the only available
    /// answers are confessions, and a person handed nothing but confessions stops answering
    /// entirely. Losing the answer loses the pattern, the fix, and the trust, in that order.
    var answerOptions: [PatternAnswerOption] {
        switch self {
        case .timeFit:
            return [
                PatternAnswerOption(
                    id: "timeFit.moveLater",
                    text: "Yes, move it later.",
                    timeTemplate: "Yes, move it to %@.",
                    action: .rescheduleSlot(slotIndex: nil, to: nil)
                ),
                PatternAnswerOption(
                    id: "timeFit.pickTime",
                    text: "A different time would be better.",
                    // No concrete target: the user picks. Remli does not guess a second time.
                    action: .rescheduleSlot(slotIndex: nil, to: nil),
                    acceptsSuggestedTime: false
                ),
                PatternAnswerOption(
                    id: "timeFit.refill",
                    text: "The time is fine — I've run out.",
                    action: .markNeedsRefill,
                    isMedicationSpecific: true
                ),
                PatternAnswerOption(
                    id: "timeFit.leaveIt",
                    text: "Leave it where it is.",
                    action: .dismissTopic
                ),
            ]

        case .silence:
            return [
                // First, always. See the note above.
                PatternAnswerOption(
                    id: "silence.justDontTap",
                    text: "I've been keeping up with it — I just don't tap.",
                    action: .acknowledgeOnly
                ),
                PatternAnswerOption(
                    id: "silence.wrongTime",
                    text: "The time doesn't work for me.",
                    action: .rescheduleSlot(slotIndex: nil, to: nil),
                    acceptsSuggestedTime: false
                ),
                PatternAnswerOption(
                    id: "silence.refill",
                    text: "I've run out and need a refill.",
                    action: .markNeedsRefill,
                    isMedicationSpecific: true
                ),
                PatternAnswerOption(
                    id: "silence.hardWeek",
                    text: "It's been a hard week.",
                    action: .acknowledgeOnly
                ),
                PatternAnswerOption(
                    id: "silence.careTeam",
                    text: "I'd rather ask my care team about this one.",
                    action: .suggestCareTeam
                ),
                PatternAnswerOption(
                    id: "silence.dismiss",
                    text: "Let's leave this one alone.",
                    action: .dismissTopic
                ),
            ]

        case .clusterFatigue:
            return [
                PatternAnswerOption(
                    id: "cluster.bundle",
                    text: "Yes — one nudge for all of them.",
                    action: .bundleReminders
                ),
                PatternAnswerOption(
                    id: "cluster.spread",
                    text: "Spread them further apart instead.",
                    action: .rescheduleSlot(slotIndex: nil, to: nil),
                    acceptsSuggestedTime: false
                ),
                PatternAnswerOption(
                    id: "cluster.leaveIt",
                    text: "Leave it as it is.",
                    action: .dismissTopic
                ),
            ]
        }
    }

    /// Baseline importance when the policy has to choose exactly one thing to raise.
    ///
    /// `timeFit` outranks the others deliberately. It rests on the strongest evidence in the app
    /// (a deliberate tap), it asks the least invasive question, and it has a fix the user can
    /// accept in one tap. `silence` ranks last despite feeling the most urgent, because urgency
    /// computed from ambiguous evidence is exactly the impulse this layer exists to restrain.
    var baseSignificance: Double {
        switch self {
        case .timeFit: return 3.0
        case .clusterFatigue: return 2.0
        case .silence: return 1.0
        }
    }

    /// Short label for debug surfaces and the local event log. Never user-facing.
    var debugLabel: String { rawValue }
}

/// What Remli will do with an answer.
///
/// # Scope boundary (rule D)
///
/// Answers about *the reminder* — wrong time, ran out, too many at once — are Remli's job, and
/// each maps to a concrete change. Answers about *the person's body* map to exactly one case,
/// `.suggestCareTeam`, whose entire implementation is: say something kind, point at the care team,
/// **write nothing down**.
///
/// Remli is a reminder app. It is not a symptom journal. It does not record side effects, does not
/// name them, does not count them, and does not correlate them with doses. That restraint is the
/// difference between a reminder app and an unregulated clinical device, and it is enforced here
/// by `persistedEffect`.
enum PatternResponseAction: Codable, Hashable, Sendable {
    /// Move a reminder time. `slotIndex` nil means "all slots"; `to` nil means "the user wants a
    /// different time but has not said which — open the picker", never "pick one for them".
    case rescheduleSlot(slotIndex: Int?, to: DateComponents?)
    /// Flag the reminder as awaiting a refill. A logistics fact about a pill box, not a clinical one.
    case markNeedsRefill
    /// Combine a cluster into a single notification. A UX decision, explicitly not a clinical one.
    case bundleReminders
    /// Heard, thank you, nothing changes. The graceful exit that makes the other answers honest.
    case acknowledgeOnly
    /// Out of Remli's scope. Acknowledge, point at the care team, **store nothing.**
    case suggestCareTeam
    /// Never raise this topic again.
    case dismissTopic

    /// What, if anything, this action writes to the vault.
    ///
    /// Exists so the scope boundary is inspectable rather than aspirational: a reviewer can read
    /// this one property and see that `.suggestCareTeam` has no persistence path at all.
    enum PersistedEffect: String, Codable, Hashable, Sendable {
        /// Nothing is written. Anywhere.
        case none
        /// A change to the reminder's approved times. Still requires the user's confirmation.
        case reminderSchedule
        /// A non-clinical flag on the reminder ("waiting on a refill").
        case reminderFlag
        /// A note in `InterruptionHistory` that this topic is closed.
        case topicMute
    }

    var persistedEffect: PersistedEffect {
        switch self {
        case .rescheduleSlot: return .reminderSchedule
        case .markNeedsRefill: return .reminderFlag
        case .bundleReminders: return .reminderSchedule
        // Answering at all closes the topic for a while; that is a note about Remli's own
        // behaviour, containing nothing the user said.
        case .acknowledgeOnly: return .topicMute
        // Rule D. If this ever returns anything else, Remli has become a symptom journal.
        case .suggestCareTeam: return .none
        case .dismissTopic: return .topicMute
        }
    }

    /// True when handling this answer writes nothing to the vault.
    var storesNothing: Bool { persistedEffect == .none }

    /// True when the answer is about the person rather than the reminder, and therefore belongs to
    /// their care team rather than to this app.
    var isOutsideRemlisScope: Bool {
        if case .suggestCareTeam = self { return true }
        return false
    }

    /// Remli's reply once the user has answered.
    ///
    /// The `.suggestCareTeam` line does three things on purpose: it does not name, guess at, or
    /// interpret whatever the user is experiencing; it points somewhere that can actually help;
    /// and it says out loud that nothing was recorded, because a person who has just mentioned
    /// something private deserves to know where it went, which is nowhere.
    var acknowledgement: String {
        switch self {
        case .rescheduleSlot:
            return "Done — I'll ask you to confirm the new time, then that's the one I'll use."
        case .markNeedsRefill:
            return "Noted. I'll keep the reminder as it is and mention the refill when it comes up."
        case .bundleReminders:
            return "I'll bundle those into one nudge. You can undo that any time."
        case .acknowledgeOnly:
            return "Thanks for telling me. Nothing changes — I just wanted to check the reminder was working."
        case .suggestCareTeam:
            return "That's one for your care team rather than me — they can actually look into it. "
                + "I've left your reminder exactly as it was, and I haven't written any of that down."
        case .dismissTopic:
            return "Understood. I won't bring this one up again."
        }
    }
}

/// One answer the user can tap.
struct PatternAnswerOption: Codable, Hashable, Identifiable, Sendable {
    /// Stable across specialization, so a UI selection and an analytics-free local log key off the
    /// same value whether or not a concrete time was woven into the label.
    let id: String
    let text: String
    let action: PatternResponseAction
    /// True for answers that only make sense for a medication ("I've run out"). The UI hides these
    /// for a therapy reminder rather than the copy having to hedge for both.
    let isMedicationSpecific: Bool
    /// Format string used when a concrete suggested time exists, e.g. `"Yes, move it to %@."`.
    let timeTemplate: String?
    /// False for the "let me pick" answer, which must stay open rather than quietly inheriting
    /// Remli's suggestion. A user asking for a different time has just told us our guess was wrong.
    let acceptsSuggestedTime: Bool

    init(
        id: String,
        text: String,
        timeTemplate: String? = nil,
        action: PatternResponseAction,
        isMedicationSpecific: Bool = false,
        acceptsSuggestedTime: Bool = true
    ) {
        self.id = id
        self.text = text
        self.timeTemplate = timeTemplate
        self.action = action
        self.isMedicationSpecific = isMedicationSpecific
        self.acceptsSuggestedTime = acceptsSuggestedTime
    }

    /// Returns a copy with the concrete slot and, where the answer accepts one, the suggested time.
    func resolving(slotIndex: Int?, suggestedTime: DateComponents?) -> PatternAnswerOption {
        guard case .rescheduleSlot(let existingSlot, let existingTime) = action else { return self }
        let time = acceptsSuggestedTime ? (existingTime ?? suggestedTime) : existingTime
        let label: String
        if let time, let timeTemplate {
            label = String(format: timeTemplate, AdherenceClock.string(from: time))
        } else {
            label = text
        }
        return PatternAnswerOption(
            id: id,
            text: label,
            timeTemplate: timeTemplate,
            action: .rescheduleSlot(slotIndex: existingSlot ?? slotIndex, to: time),
            isMedicationSpecific: isMedicationSpecific,
            acceptsSuggestedTime: acceptsSuggestedTime
        )
    }
}

/// Something Remli noticed, ready to be raised — if the interruption budget allows, which it
/// usually does not.
///
/// Detection and interruption are separate on purpose. `PatternDetector` may produce five of these
/// in a week; `InterruptionPolicy` will raise at most one, and only if it has been quiet for three
/// days. A `NoticedPattern` is a candidate, never a scheduled conversation.
///
/// `basis` deliberately carries no medication or exercise name. It feeds
/// `Provenance.patternNoticed`, and the card that renders it already shows which reminder it is
/// about; repeating the name here would put a drug name into a second file for no benefit.
struct NoticedPattern: Codable, Hashable, Identifiable, Sendable {
    /// Stable per `(reminderID, kind)`, so cooldowns and mutes key off it across app launches.
    /// Deliberately *not* unique per detection — the whole point is that the same observation two
    /// weeks later is recognizably the same topic and stays muted.
    let id: String
    let reminderID: String
    let kind: PatternKind
    /// How many occurrences supported this. An honest count of *our* records, nothing more.
    let occurrenceCount: Int
    let windowDays: Int
    let detectedAt: Date
    /// Plain language, feeds `Provenance.patternNoticed(basis:)`. Describes what Remli observed
    /// about its own reminders — never what the user did or did not do with a medication.
    let basis: String

    /// The slot this is about, when it is about one slot. `timeFit` always has it.
    let slotIndex: Int?
    /// The later time derived from the user's actual snooze behaviour. Offered, never applied.
    let suggestedTime: DateComponents?
    /// Other reminders involved. Only `clusterFatigue` populates this.
    let relatedReminderIDs: [String]

    init(
        reminderID: String,
        kind: PatternKind,
        occurrenceCount: Int,
        windowDays: Int,
        detectedAt: Date,
        basis: String,
        slotIndex: Int? = nil,
        suggestedTime: DateComponents? = nil,
        relatedReminderIDs: [String] = []
    ) {
        self.id = Self.makeID(reminderID: reminderID, kind: kind)
        self.reminderID = reminderID
        self.kind = kind
        self.occurrenceCount = occurrenceCount
        self.windowDays = windowDays
        self.detectedAt = detectedAt
        self.basis = basis
        self.slotIndex = slotIndex
        self.suggestedTime = suggestedTime
        self.relatedReminderIDs = relatedReminderIDs
    }

    static func makeID(reminderID: String, kind: PatternKind) -> String {
        "\(reminderID)#\(kind.rawValue)"
    }

    /// The design doc's "Pattern noticed" category, as a value.
    ///
    /// This layer is what finally produces one. Everything else in the app carries
    /// `.fromYourRecord`, `.needsReview`, or `.convenienceSuggestion`; a routine inference had no
    /// source until now.
    var provenance: Provenance { .patternNoticed(basis: basis) }

    /// The opener, with the honest counts woven in.
    ///
    /// Read these out loud before changing them. Every clause is either something Remli did
    /// ("I've sent this", "I haven't heard back") or a question. None of them is a statement about
    /// doses, and none of them uses the word "missed".
    var question: String {
        switch kind {
        case .timeFit:
            let slotClause = suggestedTime.map { " Would \(AdherenceClock.string(from: $0)) suit you better?" }
                ?? " Would a different time suit you better?"
            return "I've noticed this one gets pushed back a lot — \(countPhrase) "
                + "in the last \(windowPhrase)."
                + slotClause
        case .silence:
            // "hasn't come back to me as done" rather than "you haven't taken it". The first is a
            // fact about Remli's own records and is true whether the user tapped nothing or told
            // us it slipped. The second is a claim about a person's body that this app has no way
            // of knowing and is never permitted to make.
            return "I've sent this reminder \(countPhrase) in the last \(windowPhrase), "
                + "and it hasn't come back to me as done. "
                + "That might just mean you don't tap the button — I honestly can't tell from here. "
                + "Can I ask which it is?"
        case .clusterFatigue:
            let count = max(relatedReminderIDs.count, 2)
            return "\(count.spelledOutCapitalized) of your reminders land within half an hour of "
                + "each other, and I don't often hear back from them. "
                + "Would one nudge instead of \(count.spelledOut) be easier?"
        }
    }

    /// The answers, with any concrete time filled in.
    ///
    /// - Parameter reminderKind: used only to drop refill answers from an exercise reminder. The
    ///   copy is otherwise identical for both.
    func answerOptions(for reminderKind: ReminderKind? = nil) -> [PatternAnswerOption] {
        kind.answerOptions
            .filter { option in
                guard option.isMedicationSpecific else { return true }
                guard let reminderKind else { return true }
                return reminderKind == .medication
            }
            .map { $0.resolving(slotIndex: slotIndex, suggestedTime: suggestedTime) }
    }

    /// Convenience for call sites that do not have the reminder to hand.
    var answerOptions: [PatternAnswerOption] { answerOptions(for: nil) }

    /// Ranking input for `InterruptionPolicy`. Higher wins.
    ///
    /// Kind dominates; evidence count is a tie-breaker with a hard ceiling so a reminder that has
    /// been silent for forty days cannot out-shout a fresh, actionable observation. Freshness
    /// contributes a small amount so that between two equal candidates, the one still happening
    /// wins over the one that stopped a fortnight ago.
    var significance: Double {
        let evidence = min(Double(occurrenceCount), 8.0) * 0.1
        let density = Double(occurrenceCount) / Double(max(windowDays, 1)) * 0.1
        return kind.baseSignificance + evidence + min(density, 0.5)
    }

    /// One-line, PHI-free description for the debug console.
    var debugDescription: String {
        "\(kind.debugLabel) reminder=\(reminderID) n=\(occurrenceCount)/\(windowDays)d "
            + "significance=\(String(format: "%.2f", significance))"
    }

    private var countPhrase: String {
        occurrenceCount == 1 ? "once" : "\(occurrenceCount) times"
    }

    private var windowPhrase: String {
        switch windowDays {
        case 7: return "week"
        case 14: return "two weeks"
        case 30: return "month"
        default: return "\(windowDays) days"
        }
    }
}

/// Clock formatting for the small number of times this layer has to say one out loud.
///
/// Kept in one place so a suggested time reads the same in the question, in the answer button, and
/// on the card. Uses the user's locale, so 08:45 shows as "8:45 AM" or "08:45" as they expect.
enum AdherenceClock {
    static func string(from components: DateComponents) -> String {
        guard let hour = components.hour, let minute = components.minute else { return "—" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        guard let date = calendar.date(
            from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)
        ) else { return "—" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Minutes since midnight, for clustering and arithmetic.
    static func minutesOfDay(_ components: DateComponents) -> Int? {
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return hour * 60 + minute
    }

    static func components(fromMinutesOfDay minutes: Int) -> DateComponents {
        DateComponents(hour: (minutes / 60) % 24, minute: minutes % 60)
    }
}

private extension Int {
    /// Small-number spelling so the copy reads as speech rather than as a report.
    var spelledOut: String {
        switch self {
        case 2: return "two"
        case 3: return "three"
        case 4: return "four"
        case 5: return "five"
        default: return "\(self)"
        }
    }

    var spelledOutCapitalized: String {
        let word = spelledOut
        guard let first = word.first else { return word }
        return String(first).uppercased() + word.dropFirst()
    }
}
