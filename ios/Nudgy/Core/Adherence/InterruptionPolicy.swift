import Foundation

/// What Nudgy remembers about its own interruptions.
///
/// Read what is *not* in here: no answer text, no option identifier, no note about what the user
/// said. This file records when Nudgy spoke and whether anyone replied — facts about the app's
/// behaviour, not about the person's. That is deliberate, and it is what makes it safe for
/// `.suggestCareTeam` to leave nothing behind.
struct InterruptionHistory: Codable, Hashable, Sendable {

    /// Per-topic bookkeeping, keyed by `NoticedPattern.id` — which is stable per
    /// `(reminderID, kind)`, so the same observation next month is recognizably the same topic.
    struct TopicState: Codable, Hashable, Sendable {
        let patternID: String
        /// How many times Nudgy has raised this topic, ever.
        var raisedCount: Int = 0
        /// Consecutive raises that got no reply. Reset by any answer.
        var ignoredStreak: Int = 0
        var lastRaisedAt: Date?
        /// Set only for answers that are Nudgy's business. See `record(answered:)`.
        var lastAnsweredAt: Date?
        /// Nothing about this topic may be raised before this instant.
        var quietUntil: Date?
        /// The user closed this topic, or ignored it enough times that continuing would be nagging.
        var isPermanentlyMuted: Bool = false

        init(patternID: String) {
            self.patternID = patternID
        }

        func isEligible(at now: Date) -> Bool {
            guard !isPermanentlyMuted else { return false }
            guard let quietUntil else { return true }
            return now >= quietUntil
        }
    }

    private(set) var topics: [String: TopicState] = [:]
    /// The last time Nudgy interrupted about anything at all. Backs the global budget.
    private(set) var lastCheckInAt: Date?

    /// Check-ins raised since the app came to the foreground.
    ///
    /// Not persisted: a fresh launch is a fresh app open by definition, and a value that survived
    /// termination would silence the very first check-in after a crash. Excluded from `CodingKeys`
    /// rather than reset on load, so it cannot be forgotten.
    var checkInsThisAppOpen: Int = 0

    private enum CodingKeys: String, CodingKey {
        case topics
        case lastCheckInAt
    }

    init() {}

    /// Call when the app becomes active. Resets the per-open cap and nothing else.
    mutating func beginAppOpen() {
        checkInsThisAppOpen = 0
    }

    func state(for patternID: String) -> TopicState? { topics[patternID] }

    func isPermanentlyMuted(_ patternID: String) -> Bool {
        topics[patternID]?.isPermanentlyMuted ?? false
    }

    /// Every topic the user has closed for good. Surfaced in Settings so "Nudgy went quiet about
    /// this" is inspectable and reversible rather than mysterious.
    var permanentlyMutedTopicIDs: [String] {
        topics.values.filter(\.isPermanentlyMuted).map(\.patternID).sorted()
    }

    /// Lets the user reopen a topic they muted. The one escape hatch from a permanent mute, and it
    /// exists because "permanent" should be the user's decision to undo, not ours to override.
    mutating func unmute(patternID: String) {
        guard var topic = topics[patternID] else { return }
        topic.isPermanentlyMuted = false
        topic.ignoredStreak = 0
        topic.quietUntil = nil
        topics[patternID] = topic
    }

    mutating func mutateTopic(_ patternID: String, _ body: (inout TopicState) -> Void) {
        var topic = topics[patternID] ?? TopicState(patternID: patternID)
        body(&topic)
        topics[patternID] = topic
    }

    mutating func noteCheckIn(at date: Date) {
        lastCheckInAt = date
        checkInsThisAppOpen += 1
    }

    /// Drops bookkeeping for topics that are neither muted nor in backoff and have been quiet for
    /// a long time. Mutes are kept forever — forgetting one would resurrect a conversation the user
    /// ended.
    mutating func prune(now: Date, keepingFor retention: TimeInterval = 180 * 24 * 60 * 60) {
        topics = topics.filter { _, topic in
            if topic.isPermanentlyMuted || topic.ignoredStreak > 0 { return true }
            guard let lastRaisedAt = topic.lastRaisedAt else { return false }
            return now.timeIntervalSince(lastRaisedAt) < retention
        }
    }
}

/// Why Nudgy said nothing. Useful in the debug console, and useful when someone asks "why didn't it
/// notice?" — the honest answer is usually "it did, and it decided not to bother you."
enum StayQuietReason: String, Codable, Hashable, Sendable {
    /// Everything is current. The normal case, by an enormous margin.
    case nothingNoticed
    /// The one-per-app-open cap. Hard.
    case alreadyCheckedInThisAppOpen
    /// Less than the global gap since the last check-in.
    case withinGlobalBudget
    /// Patterns exist, but every one is in cooldown, in backoff, or muted.
    case allCandidatesQuiet
}

enum CheckInDecision: Hashable, Sendable {
    case raise(NoticedPattern)
    case stayQuiet(StayQuietReason)

    var pattern: NoticedPattern? {
        if case .raise(let pattern) = self { return pattern }
        return nil
    }
}

/// The interruption budget. The part of this feature that decides how much of a person's attention
/// Nudgy is entitled to, which is: almost none.
///
/// # The product rule
///
/// > The name is Nudgy and the joke is she hardly ever nudges.
///
/// Everything below is that sentence written as arithmetic. The failure mode this guards against
/// is not a bug; it is drift. Each individual check-in seems reasonable when you look at it alone,
/// and the sum of reasonable check-ins is an app people mute. So the budget is enforced centrally,
/// it is stingy, and it defaults to silence at every branch.
///
/// # The rules
///
/// - **One check-in per app open.** A hard cap, kept even in `debugRelaxed`. Opening the app to
///   look at a medication should never turn into an interview.
/// - **One check-in per three days, globally.** Regardless of how many patterns fired. Five
///   observations do not buy five interruptions; they compete for the same single slot.
/// - **Rank, take one, discard the rest.** The discarded ones are not queued. If they still matter
///   in three days they will be re-detected from the same evidence; if they stopped mattering,
///   they should not resurface.
/// - **Silence when everything is current.** There is no "all good!" check-in, no weekly summary,
///   no streak. An app that speaks only when it has something to ask is an app whose speech means
///   something.
/// - **A raised topic cannot re-fire for 14 days.**
/// - **Raised and ignored twice → permanently muted for that topic**, with exponential backoff on
///   the way there. Two ignored questions is an answer.
///
/// A plain value type. All state lives in `InterruptionHistory`, passed in, so the policy is pure
/// and every one of these rules is testable without a device or a clock.
struct InterruptionPolicy: Sendable {

    struct Budget: Hashable, Sendable {
        /// **Hard cap.** Not relaxed for demos, not raised by a pattern being urgent.
        var checkInsPerAppOpen: Int = 1
        /// Global minimum gap between any two check-ins about anything.
        var minimumGapBetweenCheckIns: TimeInterval = 3 * 24 * 60 * 60
        /// A raised topic sleeps this long before it can be raised again.
        var topicCooldown: TimeInterval = 14 * 24 * 60 * 60
        /// Ignores before a topic is muted for good.
        var ignoresBeforePermanentMute: Int = 2
        /// Backoff growth per ignore, applied to `topicCooldown`.
        var backoffMultiplier: Double = 2.0
        /// Ceiling on backoff, so an intermediate state cannot silently become a permanent one by
        /// arithmetic instead of by the rule that is supposed to decide it.
        var maximumBackoff: TimeInterval = 90 * 24 * 60 * 60

        init() {}
    }

    var budget: Budget

    init(budget: Budget = Budget()) {
        self.budget = budget
    }

    /// **Demo mode.** Collapses the waiting periods so a check-in can be produced on stage.
    ///
    /// `checkInsPerAppOpen` stays at 1. It is the one rule whose violation is immediately visible
    /// to an audience as the app talking over itself, and it is also the rule most likely to be
    /// left switched on by accident.
    static var debugRelaxed: InterruptionPolicy {
        var budget = Budget()
        budget.minimumGapBetweenCheckIns = 0
        budget.topicCooldown = 0
        budget.maximumBackoff = 60
        return InterruptionPolicy(budget: budget)
    }

    // MARK: - Selection

    /// The single thing worth interrupting for, or nil.
    ///
    /// Nil is the expected answer. On a normal day, with a normal ledger, this returns nil.
    func selectCheckIn(
        from patterns: [NoticedPattern],
        history: InterruptionHistory,
        now: Date
    ) -> NoticedPattern? {
        decide(from: patterns, history: history, now: now).pattern
    }

    /// `selectCheckIn` with the reasoning attached, for the debug console.
    func decide(
        from patterns: [NoticedPattern],
        history: InterruptionHistory,
        now: Date
    ) -> CheckInDecision {
        // Ordered cheapest-and-most-common first, so the usual path through this function is three
        // comparisons ending in silence.
        guard !patterns.isEmpty else { return .stayQuiet(.nothingNoticed) }

        guard history.checkInsThisAppOpen < budget.checkInsPerAppOpen else {
            return .stayQuiet(.alreadyCheckedInThisAppOpen)
        }

        if let lastCheckInAt = history.lastCheckInAt,
           now.timeIntervalSince(lastCheckInAt) < budget.minimumGapBetweenCheckIns {
            return .stayQuiet(.withinGlobalBudget)
        }

        let eligible = patterns.filter { pattern in
            history.state(for: pattern.id)?.isEligible(at: now) ?? true
        }
        guard !eligible.isEmpty else { return .stayQuiet(.allCandidatesQuiet) }

        // Rank, take one, discard the rest. The rest are not queued anywhere.
        let ranked = eligible.sorted {
            $0.significance == $1.significance ? $0.id < $1.id : $0.significance > $1.significance
        }
        guard let winner = ranked.first else { return .stayQuiet(.allCandidatesQuiet) }
        return .raise(winner)
    }

    // MARK: - Recording

    /// Nudgy asked. Starts the 14-day topic cooldown and spends the global budget.
    ///
    /// Called at the moment the check-in is *shown*, not when it is answered. A question the user
    /// scrolled past still cost them the interruption.
    func record(raised pattern: NoticedPattern, in history: inout InterruptionHistory, now: Date) {
        history.mutateTopic(pattern.id) { topic in
            topic.raisedCount += 1
            topic.lastRaisedAt = now
            topic.quietUntil = now.addingTimeInterval(budget.topicCooldown)
        }
        history.noteCheckIn(at: now)
    }

    /// The user replied.
    ///
    /// # What gets written, precisely
    ///
    /// The ignored streak resets, and — for answers that are Nudgy's own business — a timestamp
    /// saying a conversation happened. **The answer itself is never stored.** Not the option, not
    /// its text, not a derived flag. `InterruptionHistory` has nowhere to put it, by design.
    ///
    /// `.dismissTopic` mutes the topic permanently, because "leave this one alone" is an
    /// instruction about Nudgy's behaviour and it deserves to be honoured literally.
    ///
    /// `.suggestCareTeam` (rule D) writes **nothing at all**: no timestamp, no flag, no note. The
    /// user has just said something belongs to their doctor rather than to this app, and the app's
    /// correct response is to say so warmly and forget it. The 14-day cooldown recorded by
    /// `record(raised:)` is already enough to keep Nudgy from asking again.
    ///
    /// The caller must be equally disciplined: on `.suggestCareTeam`, do not write a
    /// `ProposalFlag`, do not append to the conversation vault, do not modify the reminder, and do
    /// not ask a follow-up question. Show `PatternResponseAction.acknowledgement` and stop.
    func record(
        answered pattern: NoticedPattern,
        with action: PatternResponseAction? = nil,
        in history: inout InterruptionHistory,
        now: Date
    ) {
        if action?.storesNothing == true { return }

        history.mutateTopic(pattern.id) { topic in
            topic.ignoredStreak = 0
            topic.lastAnsweredAt = now
            if case .dismissTopic = action {
                topic.isPermanentlyMuted = true
            }
        }
    }

    /// The check-in was shown and went unanswered — dismissed, swiped away, or left behind when the
    /// app was closed.
    ///
    /// Backoff doubles each time, and the second ignore mutes the topic for good.
    ///
    /// Two ignored questions is itself an answer, and the app should be able to hear it. The
    /// alternative — asking a third time, more insistently — is the behaviour that gets health apps
    /// deleted, and it would be the exact opposite of the one thing this product promises.
    func record(ignored pattern: NoticedPattern, in history: inout InterruptionHistory, now: Date) {
        history.mutateTopic(pattern.id) { topic in
            topic.ignoredStreak += 1
            if topic.ignoredStreak >= budget.ignoresBeforePermanentMute {
                topic.isPermanentlyMuted = true
                topic.quietUntil = nil
            } else {
                let growth = pow(budget.backoffMultiplier, Double(topic.ignoredStreak))
                let backoff = min(budget.topicCooldown * growth, budget.maximumBackoff)
                topic.quietUntil = now.addingTimeInterval(backoff)
            }
        }
    }
}

// NOTE: this file previously also defined `InterruptionHistoryStore`, which persisted the history
// through an `AdherenceVaultPersisting` abstraction declared in a sibling file that never
// compiled. `NudgySession` owns that persistence directly against `EncryptedVault`, so the
// indirection bought nothing and the class was removed rather than repaired.

