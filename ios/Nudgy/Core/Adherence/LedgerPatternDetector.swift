import Foundation

/// Turns what the ledger recorded into things worth asking about.
///
/// Deliberately conservative. Every pattern here is a statement about *our inbox* — how many
/// reminders went unanswered, how often one got snoozed — and never about the person's body. The
/// question that follows has to be answerable honestly by someone who has been taking their
/// medication perfectly and simply doesn't tap buttons.
///
/// `silence` ships disabled. Its wording is the most consequential in the app and deserves review
/// before it speaks to anyone; `timeFit` carries no such risk, since "this keeps getting snoozed,
/// want it later?" is a scheduling observation with no clinical reading at all.
struct LedgerPatternDetector {

    struct Options {
        /// Snoozes on one reminder within the window before its time is worth questioning.
        var snoozesForTimeFit = 3
        /// Unanswered occurrences before silence is worth raising.
        var unansweredForSilence = 3
        var windowDays = 7
        /// Off by default. See the type comment.
        var silenceDetectionEnabled = false

        init() {}
    }

    var options = Options()

    init(options: Options = Options()) {
        self.options = options
    }

    func patterns(
        in events: [AdherenceEvent],
        reminders: [ApprovedReminder],
        now: Date = Date()
    ) -> [NoticedPattern] {
        let window = now.addingTimeInterval(-Double(options.windowDays) * 24 * 3600)
        let recent = events.filter { $0.dueAt >= window }
        guard !recent.isEmpty else { return [] }

        let byReminder = Dictionary(grouping: recent, by: \.reminderID)
        var found: [NoticedPattern] = []

        for (reminderID, reminderEvents) in byReminder {
            guard let reminder = reminders.first(where: { $0.id == reminderID }),
                  reminder.isActive else { continue }

            // --- Time fit: repeatedly pushed back, so the time is probably wrong. ---
            let snoozes = reminderEvents.filter { $0.outcome == .snoozed }
            if snoozes.count >= options.snoozesForTimeFit {
                found.append(
                    NoticedPattern(
                        reminderID: reminderID,
                        kind: .timeFit,
                        occurrenceCount: snoozes.count,
                        windowDays: options.windowDays,
                        detectedAt: now,
                        basis: "snoozed \(snoozes.count) times in the last "
                            + "\(options.windowDays) days",
                        suggestedTime: Self.laterTime(than: reminder.times.first)
                    )
                )
            }

            // --- Silence: nothing came back. Weak evidence, hence the gate. ---
            guard options.silenceDetectionEnabled else { continue }
            let unanswered = reminderEvents.filter {
                $0.outcome == .noResponse || $0.outcome == .reportedSkipped
            }
            if unanswered.count >= options.unansweredForSilence {
                found.append(
                    NoticedPattern(
                        reminderID: reminderID,
                        kind: .silence,
                        occurrenceCount: unanswered.count,
                        windowDays: options.windowDays,
                        detectedAt: now,
                        basis: "\(unanswered.count) went by without an answer in the last "
                            + "\(options.windowDays) days"
                    )
                )
            }
        }
        return found
    }

    /// A later time to offer, rounded to something a person would actually say.
    ///
    /// Nudgy proposes exactly one alternative and no more. Offering a menu of times turns a
    /// question into a configuration screen, which is not what someone wants when they are being
    /// asked about a reminder they have been dismissing.
    static func laterTime(than current: DateComponents?) -> DateComponents? {
        guard let hour = current?.hour, let minute = current?.minute else { return nil }
        let shifted = hour * 60 + minute + 90
        guard shifted < 22 * 60 else { return nil }
        let rounded = (shifted / 15) * 15
        return DateComponents(hour: rounded / 60, minute: rounded % 60)
    }
}
