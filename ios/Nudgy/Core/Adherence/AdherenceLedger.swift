import Foundation

/// What we honestly know about whether reminders are being acted on.
///
/// ## The one thing this type refuses to do
///
/// iOS cannot tell us a pill was taken. We know only what the person told us — Done, Not this
/// time, Snooze — and silence. **Silence is ambiguous**: a phone face-down in a bag is
/// indistinguishable from a genuinely missed dose.
///
/// So this records *our* facts, never the patient's. The status it produces means "several
/// reminders have gone unanswered", and must never be rendered as "you have missed three doses".
/// The colour is a prompt to look, not an accusation — and an accusation is a thing people stop
/// answering, which would destroy the only signal we have.
///
/// This is also why the "Not this time" notification action matters: it converts silence into
/// something the person actually said.
struct AdherenceEvent: Codable, Hashable, Identifiable {
    enum Outcome: String, Codable, Hashable {
        /// Tapped Done. The strongest signal available.
        case acknowledged
        /// Tapped Not this time — a reported skip, not an inferred one.
        case reportedSkipped
        case snoozed
        /// Delivered, nothing heard. Weak and ambiguous by nature.
        case noResponse
    }

    let id: String
    let reminderID: String
    let dueAt: Date
    var outcome: Outcome
    var recordedAt: Date
}

/// Green / amber / red, as a status light rather than a score.
///
/// Not a streak. A streak punishes being ill — three days in hospital should not cost someone a
/// 47-day counter at the moment they most need the app to feel like an ally. This is a rolling
/// window that recovers on its own.
enum AdherenceStatus: String, Codable, Hashable {
    case current
    case attention
    case needsLook

    /// Deliberately about our inbox, not their body.
    var summary: String {
        switch self {
        case .current: return "Everything's up to date"
        case .attention: return "One or two haven't been answered"
        case .needsLook: return "A few have gone by unanswered"
        }
    }
}

@MainActor
final class AdherenceLedger: ObservableObject {
    @Published private(set) var events: [AdherenceEvent] = []
    @Published private(set) var status: AdherenceStatus = .current

    private let vault: EncryptedVault
    private static let fileName = "adherence"
    /// Anything older is pruned. This is a status light, not an archive.
    private let retentionDays = 30

    init(vault: EncryptedVault = EncryptedVault()) {
        self.vault = vault
    }

    func load() {
        events = (try? vault.read([AdherenceEvent].self, from: Self.fileName)) ?? []
        prune()
        recomputeStatus()
    }

    /// Records an outcome the user actually reported.
    func record(reminderID: String, outcome: AdherenceEvent.Outcome, dueAt: Date = Date()) {
        let id = "\(reminderID)#\(Int(dueAt.timeIntervalSince1970))"
        if let index = events.firstIndex(where: { $0.id == id }) {
            events[index].outcome = outcome
            events[index].recordedAt = Date()
        } else {
            events.append(
                AdherenceEvent(
                    id: id,
                    reminderID: reminderID,
                    dueAt: dueAt,
                    outcome: outcome,
                    recordedAt: Date()
                )
            )
        }
        persist()
    }

    /// Fills in occurrences that have passed with nothing heard.
    ///
    /// Derived from our own schedule minus our own ledger — iOS never tells us this. Deliberately
    /// does not backfill before a reminder was approved, so turning on a reminder today does not
    /// instantly show a week of red.
    func materializeElapsed(for reminders: [ApprovedReminder], now: Date = Date()) {
        let calendar = Calendar.current
        for reminder in reminders where reminder.isActive {
            for time in reminder.times {
                guard let hour = time.hour, let minute = time.minute else { continue }
                for dayOffset in 0..<7 {
                    guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now),
                          let due = calendar.date(
                            bySettingHour: hour, minute: minute, second: 0, of: day
                          ) else { continue }
                    guard due <= now, due >= reminder.approvedAt else { continue }
                    let id = "\(reminder.id)#\(Int(due.timeIntervalSince1970))"
                    if !events.contains(where: { $0.id == id }) {
                        events.append(
                            AdherenceEvent(
                                id: id,
                                reminderID: reminder.id,
                                dueAt: due,
                                outcome: .noResponse,
                                recordedAt: now
                            )
                        )
                    }
                }
            }
        }
        prune()
        persist()
    }

    // MARK: - Status

    /// Thresholds match the check-in trigger, so the light turning red and Nudgy asking about it
    /// are the same event rather than two systems disagreeing.
    private func recomputeStatus() {
        let window = Date().addingTimeInterval(-7 * 24 * 3600)
        let recent = events.filter { $0.dueAt >= window }
        let unanswered = recent.filter {
            $0.outcome == .noResponse || $0.outcome == .reportedSkipped
        }

        // Per reminder, so one neglected medication shows up even when everything else is fine.
        let worst = Dictionary(grouping: unanswered, by: \.reminderID)
            .values.map(\.count).max() ?? 0

        status = worst >= 3 ? .needsLook : (worst >= 1 ? .attention : .current)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 3600)
        events.removeAll { $0.dueAt < cutoff }
    }

    private func persist() {
        recomputeStatus()
        let snapshot = events
        Task.detached { [vault] in
            try? vault.write(snapshot, to: AdherenceLedger.fileName)
        }
    }

    func wipe() {
        events = []
        status = .current
        try? vault.delete(Self.fileName)
    }
}
