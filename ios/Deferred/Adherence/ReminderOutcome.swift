import Foundation

/// How much a single observation is actually worth as evidence.
///
/// This exists because the four `ReminderOutcome` cases look symmetrical and are not. Two of them
/// are things the user *told* us. Two of them are things we *inferred from the absence of a tap*.
/// Ranking them in the type system means a future caller has to go out of its way to treat a
/// non-event as a fact.
enum SignalStrength: Int, Codable, Hashable, Comparable, Sendable {
    /// We know nothing. Reserved; no outcome currently produces it.
    case none = 0
    /// We heard nothing. Consistent with a hundred different realities. See `.noResponse`.
    case ambiguous = 1
    /// The user physically interacted with the reminder, but told us nothing about the dose itself.
    case interaction = 2
    /// The user told us in words. The only kind of evidence Remli may ever restate as a fact.
    case told = 3

    static func < (lhs: SignalStrength, rhs: SignalStrength) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What we honestly observed for one scheduled occurrence of a reminder.
///
/// # The rule this type exists to enforce
///
/// **iOS cannot tell us whether a pill was taken.** It can tell us that we posted a notification
/// and that nobody tapped anything. Those are completely different facts, and the distance between
/// them is where adherence products go wrong.
///
/// So this enum records *our own* events only:
///
/// - `.acknowledged` — the user tapped Done. A told fact.
/// - `.snoozed` — the user tapped Snooze. A real interaction, but it says something about the
///   *timing of the reminder*, not about the medication.
/// - `.dismissedAsSkipped` — the user explicitly told us it slipped. A told fact, and the **only**
///   case that may ever be described back to the user as a missed dose, because they said so.
/// - `.noResponse` — nothing happened. See below.
///
/// # `.noResponse` is not a missed dose
///
/// A phone face-down in a bag, a notification cleared by a swipe on the lock screen, a dose taken
/// from the pill box thirty seconds before the alarm, Do Not Disturb, a dead battery, and a
/// genuinely forgotten medication all produce **byte-for-byte identical** `.noResponse` records.
/// There is no way to tell them apart, and there never will be from inside an iOS app.
///
/// Therefore:
///
/// 1. `.noResponse` must never be rendered, narrated, summarized, or exported as "missed",
///    "skipped", "non-adherent", or any synonym.
/// 2. Anything Remli says about a run of `.noResponse` must be phrased as a statement about
///    *Remli's own experience* — "I haven't heard back about this four times this week" — never as
///    a statement about the person's body or behaviour.
/// 3. It may open a question. It may never support a conclusion.
///
/// `PatternDetector` and `NoticedPattern` are written around this and the silence detector ships
/// disabled by default for exactly this reason.
enum ReminderOutcome: Codable, Hashable, Sendable {
    /// The user tapped Done on the notification or the card.
    case acknowledged(at: Date)
    /// The user tapped Snooze. `count` is how many times for this one occurrence.
    case snoozed(count: Int, lastAt: Date)
    /// The user explicitly said this one slipped. A told fact — the user's own words, not our guess.
    case dismissedAsSkipped(at: Date)
    /// We never heard anything. **Weak, ambiguous signal.** Read the type documentation before using.
    case noResponse

    var signalStrength: SignalStrength {
        switch self {
        case .acknowledged: return .told
        case .dismissedAsSkipped: return .told
        case .snoozed: return .interaction
        case .noResponse: return .ambiguous
        }
    }

    /// True when the user put this fact into the record themselves.
    ///
    /// Gate every sentence that describes what the *person* did behind this. Everything else is a
    /// sentence about what *Remli* did.
    var isToldByUser: Bool { signalStrength == .told }

    /// When we last heard anything at all about this occurrence.
    var lastHeardAt: Date? {
        switch self {
        case .acknowledged(let at): return at
        case .dismissedAsSkipped(let at): return at
        case .snoozed(_, let lastAt): return lastAt
        case .noResponse: return nil
        }
    }

    /// How many times the user pushed this occurrence back. Zero for everything but `.snoozed`.
    var snoozeCount: Int {
        if case .snoozed(let count, _) = self { return count }
        return 0
    }

    /// True when we heard nothing. Named so call sites read as what they are and cannot be mistaken
    /// for `wasMissed`, which is a question this app is not able to answer.
    var isSilent: Bool {
        if case .noResponse = self { return true }
        return false
    }

    /// Short, honest description for debug surfaces and the local (PHI-free) event log.
    ///
    /// Deliberately not user-facing copy. User-facing copy lives in `NoticedPattern`, where it can
    /// be reviewed as a whole.
    var debugSummary: String {
        switch self {
        case .acknowledged: return "user tapped Done"
        case .snoozed(let count, _): return "user snoozed \(count)×"
        case .dismissedAsSkipped: return "user said it slipped"
        case .noResponse: return "no response heard (ambiguous)"
        }
    }
}

/// One scheduled firing of one reminder slot, and what we observed about it.
///
/// The id is deterministic — `"<reminderID>#<slotIndex>#<ISO8601 dueAt>"` — so the same real-world
/// occurrence produces the same row whether it was created by a notification response arriving or
/// by `OutcomeLedger.materializeElapsedOccurrences` noticing that it went by. That is what makes
/// the ledger idempotent under replay, app relaunch, and clock changes.
struct ReminderOccurrence: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let reminderID: String
    let slotIndex: Int
    let dueAt: Date
    var outcome: ReminderOutcome

    init(reminderID: String, slotIndex: Int, dueAt: Date, outcome: ReminderOutcome) {
        self.id = Self.makeID(reminderID: reminderID, slotIndex: slotIndex, dueAt: dueAt)
        self.reminderID = reminderID
        self.slotIndex = slotIndex
        self.dueAt = dueAt
        self.outcome = outcome
    }

    /// Stable identity for a scheduled occurrence.
    ///
    /// Seconds-precision ISO 8601 in UTC. UTC rather than local time because the id has to survive
    /// the user flying somewhere: a local-time id would silently split one occurrence into two
    /// across a timezone change, and the ledger would grow phantom silences.
    static func makeID(reminderID: String, slotIndex: Int, dueAt: Date) -> String {
        "\(reminderID)#\(slotIndex)#\(iso8601.string(from: dueAt))"
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// How late the user's response was, when there was one. Nil when we heard nothing.
    ///
    /// This is the raw material for the `timeFit` pattern: a Done tap that consistently lands
    /// forty minutes after the alarm is the same signal as a snooze, and it is a signal about the
    /// *reminder's time*, not about the person.
    var responseDelay: TimeInterval? {
        guard let lastHeardAt = outcome.lastHeardAt else { return nil }
        return max(0, lastHeardAt.timeIntervalSince(dueAt))
    }
}

/// Notification action identifiers this layer reasons about, as plain strings.
///
/// Declared here rather than imported from `NotificationScheduler` so that everything under
/// `Core/Adherence` stays Foundation-only and can be exercised by a command-line harness with no
/// `UserNotifications` framework and no simulator. The app layer maps the scheduler's constants
/// onto these when a notification response arrives; the values are kept identical so that mapping
/// is a no-op today and a one-line translation if either side ever renames.
enum ReminderActionIdentifier {
    /// `NotificationScheduler.markDoneActionIdentifier`.
    static let markDone = "remli.action.markDone"
    /// `NotificationScheduler.snoozeActionIdentifier`.
    static let snooze = "remli.action.snooze15"
    /// The user said, in the app, that this one slipped. There is no notification button for this —
    /// telling us a dose was missed is a deliberate, in-app, unhurried act, never a lock-screen tap.
    static let saidItSlipped = "remli.action.saidItSlipped"

    /// How far `snooze` defers by. Mirrors `NotificationScheduler.snoozeInterval`.
    static let snoozeInterval: TimeInterval = 15 * 60
}

extension ReminderOutcome {
    /// Maps a notification action to an outcome.
    ///
    /// Returns nil for anything unrecognized — including the system's default "user tapped the
    /// notification body" action. **Opening the app is not acknowledgement.** Treating it as one
    /// would quietly convert curiosity into a claim that a dose was taken, which is the same class
    /// of error as treating silence as a miss, only in the flattering direction.
    ///
    /// - Parameter previous: the outcome already on file for this occurrence, so a second snooze
    ///   increments rather than resets.
    static func from(
        actionIdentifier: String,
        at date: Date,
        previous: ReminderOutcome? = nil
    ) -> ReminderOutcome? {
        switch actionIdentifier {
        case ReminderActionIdentifier.markDone:
            return .acknowledged(at: date)
        case ReminderActionIdentifier.saidItSlipped:
            return .dismissedAsSkipped(at: date)
        case ReminderActionIdentifier.snooze:
            return .snoozed(count: (previous?.snoozeCount ?? 0) + 1, lastAt: date)
        default:
            return nil
        }
    }
}
