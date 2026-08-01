import Foundation

/// Reads the ledger and produces candidate `NoticedPattern`s.
///
/// # Deterministic and pure
///
/// Same ledger, same reminders, same `now` → byte-identical output. No randomness, no model, no
/// clock read, no I/O, no stored state. This matters for the same reason the proposal engine is
/// deterministic: the thing that decides to interrupt someone about their medication should be
/// reviewable by reading it, and reproducible when someone reports that it said something odd.
///
/// The language model is nowhere near this file. Gemma may eventually *phrase* a check-in; it will
/// never decide that one is warranted.
///
/// # What it will not detect
///
/// Adherence rates. Trends. Improvement or decline. Correlations between reminders. Anything that
/// would require treating `.noResponse` as a measurement rather than an absence. The three kinds in
/// `PatternKind` are the whole vocabulary, on purpose.
struct PatternDetector {

    /// Thresholds and feature flags.
    ///
    /// Every number here is a product decision about when it is acceptable to interrupt somebody,
    /// so each carries its reason. None of them is tuned for engagement.
    struct Options: Hashable, Sendable {

        // MARK: Feature flags

        /// `timeFit` ships on. It rests on deliberate taps, it concludes something about a clock
        /// rather than about a person, and its question is one a reasonable person is happy to be
        /// asked.
        var timeFitDetectionEnabled: Bool = true

        /// **`silence` ships OFF.**
        ///
        /// The detection logic is finished and correct; the *wording* is what is not cleared. A
        /// silence check-in is the one place in this app where Nudgy speaks about a run of missing
        /// evidence, and there is no phrasing of that which cannot be misread as an accusation by
        /// somebody having a bad month. `.noResponse` is indistinguishable from a phone in a pocket
        /// (see `ReminderOutcome`), so being wrong here is not a rare edge case — it is expected.
        ///
        /// Before this flips to `true` it needs sign-off on the exact copy in
        /// `PatternKind.silence.question` and `answerOptions`, with particular attention to the
        /// first answer option being an unaccusing out. Shipping this without that review turns a
        /// reminder app into something that makes people feel watched, and they will turn it off.
        var silenceDetectionEnabled: Bool = false

        /// `clusterFatigue` ships on. It is framed as notification management — "shall I combine
        /// these?" — which the architecture doc already classes as a UX decision and explicitly not
        /// a clinical one.
        var clusterFatigueDetectionEnabled: Bool = true

        // MARK: timeFit

        var timeFitWindowDays: Int = 14
        /// Three deliberate pushes back. Two is a coincidence; three is a preference.
        var timeFitMinimumDeferrals: Int = 3
        /// Spread across at least two different days, so one chaotic morning of jabbing Snooze does
        /// not get read as a standing preference about the schedule.
        var timeFitMinimumDistinctDays: Int = 2
        /// A response counts as "pushed back" only past this. Fifteen minutes is one snooze; below
        /// that we are looking at how fast someone reaches their phone, not at the schedule.
        var timeFitMinimumDelay: TimeInterval = 15 * 60
        /// Never suggest moving a reminder more than four hours. Beyond that the honest answer is
        /// "pick a time", not a guess — and a large silent shift of a medication reminder starts to
        /// look like timing advice, which is out of scope.
        var timeFitMaximumSuggestedDelay: TimeInterval = 4 * 60 * 60
        /// Suggestions land on a five-minute boundary. "8:45" is an offer; "8:47" is a readout.
        var timeFitRoundingMinutes: Int = 5

        // MARK: silence

        var silenceWindowDays: Int = 7
        /// Three in a week. Chosen so a weekend away cannot trigger it.
        var silenceMinimumOccurrences: Int = 3

        // MARK: clusterFatigue

        var clusterWindowDays: Int = 7
        /// Reminders this close together arrive as one event to a human being.
        var clusterSpanMinutes: Int = 30
        /// Two reminders together is a schedule; three at once is a pile.
        var clusterMinimumReminders: Int = 3
        /// Enough history that one bad evening is not a pattern.
        var clusterMinimumOccurrences: Int = 4
        /// "Most go unanswered."
        var clusterUnansweredFraction: Double = 0.6

        init() {}

        /// **Demo mode.** Drops the evidence thresholds to near-zero so a live demo can produce a
        /// check-in from a couple of taps instead of a fortnight of real use.
        ///
        /// Note what it does *not* do: it leaves `silenceDetectionEnabled` off. Relaxing a
        /// threshold for a demo is a convenience; putting unreviewed copy in front of an audience
        /// is a different thing entirely, and a demo is exactly where it would be quoted.
        static var debugRelaxed: Options {
            var options = Options()
            options.timeFitMinimumDeferrals = 1
            options.timeFitMinimumDistinctDays = 1
            options.timeFitMinimumDelay = 60
            options.silenceMinimumOccurrences = 1
            options.clusterMinimumReminders = 2
            options.clusterMinimumOccurrences = 1
            options.clusterUnansweredFraction = 0.1
            return options
        }
    }

    var options: Options
    var calendar: Calendar

    init(options: Options = Options(), calendar: Calendar = .current) {
        self.options = options
        self.calendar = calendar
    }

    // MARK: - Entry point

    /// Every pattern currently supported by the evidence, most significant first.
    ///
    /// Returning several is fine and expected — `InterruptionPolicy` is what refuses to raise more
    /// than one. Keeping detection and interruption separate means the ranking can be tested
    /// without a budget, and the budget can be tested without a ledger.
    func patterns(
        in ledger: OutcomeLedger,
        reminders: [ApprovedReminder],
        now: Date
    ) -> [NoticedPattern] {
        var found: [NoticedPattern] = []

        let active = reminders.filter(\.isActive).sorted { $0.id < $1.id }

        if options.timeFitDetectionEnabled {
            found.append(contentsOf: timeFitPatterns(in: ledger, reminders: active, now: now))
        }
        if options.silenceDetectionEnabled {
            found.append(contentsOf: silencePatterns(in: ledger, reminders: active, now: now))
        }
        if options.clusterFatigueDetectionEnabled {
            found.append(contentsOf: clusterFatiguePatterns(in: ledger, reminders: active, now: now))
        }

        // Ids are stable per (reminder, kind), so a duplicate here is a bug in a detector rather
        // than a second real observation. Keep the strongest and move on rather than raising twice.
        var byID: [String: NoticedPattern] = [:]
        for pattern in found {
            if let existing = byID[pattern.id], existing.significance >= pattern.significance { continue }
            byID[pattern.id] = pattern
        }

        return byID.values.sorted {
            $0.significance == $1.significance ? $0.id < $1.id : $0.significance > $1.significance
        }
    }

    // MARK: - timeFit

    /// Repeated pushes back on one slot mean the time is wrong.
    ///
    /// ## What counts as a push back
    ///
    /// Two things, treated identically because they are the same human act:
    ///
    /// - an explicit **snooze**, whose implied preferred time is `lastAt + 15 minutes`; and
    /// - a **Done tap that lands materially late**, whose preferred time is when it actually landed.
    ///
    /// The second case exists because acknowledgement overwrites snooze on a single occurrence
    /// (a told fact outranks an interaction — see `OutcomeLedger.record`). Without it, the most
    /// informative user in the app — the one who snoozes twice and then reliably takes their
    /// medication — would generate no signal at all.
    ///
    /// ## What the suggestion is derived from
    ///
    /// The **median** observed delay, not the mean: one 3-hour outlier from a day someone left
    /// their phone at home should not drag a suggestion across the afternoon. Clamped to
    /// `timeFitMaximumSuggestedDelay`, rounded to a friendly boundary, and dropped entirely if it
    /// would push the reminder into the next day — a medication reminder silently proposed for
    /// after midnight is a bug that looks like advice.
    ///
    /// The suggestion is *offered*. Nothing here changes a schedule; only the user's answer does.
    private func timeFitPatterns(
        in ledger: OutcomeLedger,
        reminders: [ApprovedReminder],
        now: Date
    ) -> [NoticedPattern] {
        let windowStart = now.addingTimeInterval(-TimeInterval(options.timeFitWindowDays) * 86_400)
        var patterns: [NoticedPattern] = []

        for reminder in reminders {
            // One pattern per reminder: the worst-fitting slot. Asking about two slots of the same
            // medication in one breath is exactly the nagging this layer is built to prevent.
            var best: (pattern: NoticedPattern, delay: TimeInterval)?

            for (slotIndex, slotTime) in reminder.times.enumerated() {
                guard let slotMinutes = AdherenceClock.minutesOfDay(slotTime) else { continue }

                let occurrences = ledger.occurrences(
                    reminderID: reminder.id, slotIndex: slotIndex, from: windowStart, to: now
                )

                var delays: [TimeInterval] = []
                var deferralEvents = 0
                var days: Set<DateComponents> = []

                for occurrence in occurrences {
                    guard let delay = deferralDelay(for: occurrence) else { continue }
                    delays.append(delay)
                    // A snooze tapped four times is four pushes back, not one.
                    deferralEvents += max(occurrence.outcome.snoozeCount, 1)
                    days.insert(calendar.dateComponents([.year, .month, .day], from: occurrence.dueAt))
                }

                guard deferralEvents >= options.timeFitMinimumDeferrals,
                      days.count >= options.timeFitMinimumDistinctDays,
                      let medianDelay = Self.median(delays) else { continue }

                let suggested = suggestedTime(forSlotMinutes: slotMinutes, delay: medianDelay)
                let roundedMinutes = Int((min(medianDelay, options.timeFitMaximumSuggestedDelay) / 60).rounded())

                let basis = "Nudgy sent this reminder at \(AdherenceClock.string(from: slotTime)) and it was "
                    + "pushed back \(deferralEvents) time\(deferralEvents == 1 ? "" : "s") "
                    + "on \(days.count) different day\(days.count == 1 ? "" : "s") "
                    + "in the last \(options.timeFitWindowDays) days, by about \(roundedMinutes) minutes each time. "
                    + "This describes how the reminder was used. It says nothing about whether anything was taken."

                let pattern = NoticedPattern(
                    reminderID: reminder.id,
                    kind: .timeFit,
                    occurrenceCount: deferralEvents,
                    windowDays: options.timeFitWindowDays,
                    detectedAt: now,
                    basis: basis,
                    slotIndex: slotIndex,
                    suggestedTime: suggested
                )

                if best == nil || medianDelay > best!.delay {
                    best = (pattern, medianDelay)
                }
            }

            if let best { patterns.append(best.pattern) }
        }

        return patterns
    }

    /// How much later the user actually wanted this occurrence, or nil if they did not push it back.
    private func deferralDelay(for occurrence: ReminderOccurrence) -> TimeInterval? {
        switch occurrence.outcome {
        case .snoozed(_, let lastAt):
            // The snooze button means "ask me again in 15 minutes", so the implied preference is
            // the last snooze plus one interval.
            let implied = lastAt.addingTimeInterval(ReminderActionIdentifier.snoozeInterval)
                .timeIntervalSince(occurrence.dueAt)
            return max(implied, ReminderActionIdentifier.snoozeInterval)
        case .acknowledged:
            guard let delay = occurrence.responseDelay, delay >= options.timeFitMinimumDelay else { return nil }
            return delay
        case .dismissedAsSkipped, .noResponse:
            // Neither says anything about a preferred time. Silence in particular must not feed a
            // suggestion — a guess built on an absence is still a guess.
            return nil
        }
    }

    /// Slot time + median delay, clamped, rounded, and refused if it crosses midnight.
    private func suggestedTime(forSlotMinutes slotMinutes: Int, delay: TimeInterval) -> DateComponents? {
        let clamped = min(max(delay, options.timeFitMinimumDelay), options.timeFitMaximumSuggestedDelay)
        let step = max(options.timeFitRoundingMinutes, 1)
        let rawMinutes = Int((clamped / 60).rounded())
        let roundedMinutes = Int((Double(rawMinutes) / Double(step)).rounded()) * step
        guard roundedMinutes > 0 else { return nil }
        let target = slotMinutes + roundedMinutes
        // A reminder proposed for the following day is not a later time, it is a different day.
        guard target < 24 * 60 else { return nil }
        return AdherenceClock.components(fromMinutesOfDay: target)
    }

    // MARK: - silence

    /// Repeated occurrences that never came back as done.
    ///
    /// Gated by `Options.silenceDetectionEnabled`, which is `false`. Read that flag's
    /// documentation before turning it on.
    ///
    /// `.dismissedAsSkipped` counts alongside `.noResponse` because the user telling us it slipped
    /// is the same question — "is this reminder working for you?" — arriving with better evidence.
    /// The copy in `NoticedPattern.question` is written to be true of both.
    private func silencePatterns(
        in ledger: OutcomeLedger,
        reminders: [ApprovedReminder],
        now: Date
    ) -> [NoticedPattern] {
        let windowStart = now.addingTimeInterval(-TimeInterval(options.silenceWindowDays) * 86_400)

        return reminders.compactMap { reminder in
            let occurrences = ledger.occurrences(reminderID: reminder.id, from: windowStart, to: now)
            let unheard = occurrences.filter {
                switch $0.outcome {
                case .noResponse, .dismissedAsSkipped: return true
                case .acknowledged, .snoozed: return false
                }
            }
            guard unheard.count >= options.silenceMinimumOccurrences else { return nil }

            let silent = unheard.filter(\.outcome.isSilent).count
            let toldSlipped = unheard.count - silent

            var basis = "Nudgy sent this reminder \(occurrences.count) time"
                + "\(occurrences.count == 1 ? "" : "s") in the last \(options.silenceWindowDays) days. "
                + "\(silent) of those were never confirmed either way"
            if toldSlipped > 0 {
                basis += ", and you told Nudgy \(toldSlipped) had slipped"
            }
            basis += ". Nudgy has no way to know whether anything was taken — this records only what "
                + "the app sent and what it heard."

            return NoticedPattern(
                reminderID: reminder.id,
                kind: .silence,
                occurrenceCount: unheard.count,
                windowDays: options.silenceWindowDays,
                detectedAt: now,
                basis: basis
            )
        }
    }

    // MARK: - clusterFatigue

    /// A dense block of reminders that mostly goes unanswered.
    ///
    /// This is a notification-management observation, and its question is a notification-management
    /// question: shall I combine these? The architecture doc already treats clustering as a UX
    /// decision explicitly separated from clinical ones, and nothing here departs from that — no
    /// medication is named, nothing is reordered, and the only thing Nudgy offers to change is how
    /// many times the phone buzzes.
    ///
    /// Blocks are built greedily over the *scheduled* times, so the grouping is stable regardless
    /// of what the ledger contains; the ledger only decides whether the block is worth mentioning.
    private func clusterFatiguePatterns(
        in ledger: OutcomeLedger,
        reminders: [ApprovedReminder],
        now: Date
    ) -> [NoticedPattern] {
        struct Slot {
            let reminderID: String
            let slotIndex: Int
            let minutes: Int
        }

        let slots: [Slot] = reminders
            .flatMap { reminder in
                reminder.times.enumerated().compactMap { index, time -> Slot? in
                    guard let minutes = AdherenceClock.minutesOfDay(time) else { return nil }
                    return Slot(reminderID: reminder.id, slotIndex: index, minutes: minutes)
                }
            }
            .sorted { $0.minutes == $1.minutes ? $0.reminderID < $1.reminderID : $0.minutes < $1.minutes }

        guard !slots.isEmpty else { return [] }

        let windowStart = now.addingTimeInterval(-TimeInterval(options.clusterWindowDays) * 86_400)
        var patterns: [NoticedPattern] = []
        var index = 0

        while index < slots.count {
            let start = slots[index].minutes
            var end = index
            while end + 1 < slots.count, slots[end + 1].minutes - start <= options.clusterSpanMinutes {
                end += 1
            }
            let block = Array(slots[index...end])
            index = end + 1

            let reminderIDs = Set(block.map(\.reminderID)).sorted()
            guard reminderIDs.count >= options.clusterMinimumReminders else { continue }

            var total = 0
            var unanswered = 0
            for slot in block {
                let occurrences = ledger.occurrences(
                    reminderID: slot.reminderID, slotIndex: slot.slotIndex, from: windowStart, to: now
                )
                total += occurrences.count
                unanswered += occurrences.filter {
                    switch $0.outcome {
                    case .noResponse, .dismissedAsSkipped: return true
                    case .acknowledged, .snoozed: return false
                    }
                }.count
            }

            guard total >= options.clusterMinimumOccurrences,
                  total > 0,
                  Double(unanswered) / Double(total) >= options.clusterUnansweredFraction,
                  let anchor = reminderIDs.first else { continue }

            let basis = "\(reminderIDs.count) reminders are scheduled within "
                + "\(options.clusterSpanMinutes) minutes of each other around "
                + "\(AdherenceClock.string(from: AdherenceClock.components(fromMinutesOfDay: start))). "
                + "Over the last \(options.clusterWindowDays) days, \(unanswered) of \(total) of them "
                + "did not come back to Nudgy as done. This is about how many notifications arrive at "
                + "once, not about what was or was not taken."

            patterns.append(
                NoticedPattern(
                    reminderID: anchor,
                    kind: .clusterFatigue,
                    occurrenceCount: unanswered,
                    windowDays: options.clusterWindowDays,
                    detectedAt: now,
                    basis: basis,
                    relatedReminderIDs: reminderIDs
                )
            )
        }

        return patterns
    }

    // MARK: - Helpers

    /// Median, not mean. One outlier day should not move a suggestion.
    static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}
