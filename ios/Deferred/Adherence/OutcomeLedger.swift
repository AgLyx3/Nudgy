import Foundation

/// Vault file names owned by the adherence layer.
///
/// Deliberately separate from the medication data. This file holds behavioural traces — when a
/// phone was picked up, when a button was tapped — and it is the one thing in the vault that is
/// *not* copied from a chart. Keeping it in its own file means "forget what you noticed about me"
/// can be a single deletion that leaves the care record untouched.
///
/// Integration note: add both names to `VaultFile.all` so the "what is stored on this phone"
/// screen can enumerate them. They are chosen not to collide with `care-record`,
/// `approved-reminders`, or `skipped-proposals`.
enum AdherenceVaultFile {
    /// `OutcomeLedger`. Rolling ~60 days of scheduled-occurrence outcomes.
    static let outcomeLedger = "adherence-ledger"
    /// `InterruptionHistory`. When Remli last spoke up, and about what.
    static let interruptionHistory = "adherence-interruptions"

    static let all: [String] = [outcomeLedger, interruptionHistory]
}

/// The slice of `EncryptedVault` this layer needs.
///
/// Declared as a protocol so `Core/Adherence` stays Foundation-only: the ledger has no idea that
/// storage is AES-GCM, a file, or a dictionary in a test. The signatures are copied verbatim from
/// `EncryptedVault`, so the app declares the conformance with an empty extension:
///
/// ```swift
/// extension EncryptedVault: AdherenceVaultPersisting {}
/// ```
protocol AdherenceVaultPersisting: AnyObject {
    func write<T: Encodable>(_ value: T, to name: String) throws
    func read<T: Decodable>(_ type: T.Type, from name: String) throws -> T?
}

/// An in-memory stand-in used by harnesses and previews. Never persists anything anywhere.
final class InMemoryAdherenceVault: AdherenceVaultPersisting {
    private var files: [String: Data] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func write<T: Encodable>(_ value: T, to name: String) throws {
        files[name] = try encoder.encode(value)
    }

    func read<T: Decodable>(_ type: T.Type, from name: String) throws -> T? {
        guard let data = files[name] else { return nil }
        return try decoder.decode(T.self, from: data)
    }
}

/// The record of what happened to every scheduled reminder occurrence we know about.
///
/// # Why this exists
///
/// Without it, "nothing happened" is not an event and cannot be noticed. A notification that fires
/// into an empty room leaves no trace anywhere in iOS. `materializeElapsedOccurrences` is what
/// turns the absence into a row, and it is the only reason the proactive layer can exist at all.
///
/// # What it is not
///
/// It is **not an adherence log**. It records what Remli scheduled and what Remli heard. See
/// `ReminderOutcome` for why those are not the same as what the person did. Nothing in this type
/// may be exported, summarized, or shown as a percentage — an "82% adherence" number computed from
/// `.noResponse` rows would be a fabricated clinical statistic.
///
/// # Retention
///
/// Pruned to ~60 days. Long enough for a 14-day pattern window plus history, short enough that
/// this never becomes a longitudinal behavioural profile of somebody's illness. If a pattern was
/// not worth noticing within two months, it is not worth keeping the evidence for.
///
/// Plain value type: no actor, no observation, no I/O. `OutcomeLedgerStore` handles persistence.
struct OutcomeLedger: Codable, Hashable, Sendable {

    /// Tuning knobs, all with product reasons rather than technical ones.
    struct Options: Hashable, Sendable {
        /// How long a record survives. See the retention note on the type.
        var retention: TimeInterval = 60 * 24 * 60 * 60

        /// How long after a reminder is due we wait before calling it `.noResponse`.
        ///
        /// Not zero. A reminder that fires at 8:00 and is tapped at 8:40 is a normal morning, and
        /// materializing a silence at 8:01 would race the user's own thumb. Two hours is long
        /// enough to cover a commute and short enough that the same-day pattern is still fresh.
        var noResponseGrace: TimeInterval = 2 * 60 * 60

        /// How far from a due time a bare "user tapped Done" is still assumed to belong to that
        /// occurrence. Twelve hours, so a twice-daily reminder's two slots cannot steal each
        /// other's taps, and a late-evening Done still lands on the evening dose.
        var responseMatchWindow: TimeInterval = 12 * 60 * 60

        init() {}
    }

    /// Keyed by `ReminderOccurrence.id` so recording the same real occurrence twice converges
    /// instead of accumulating. This is the whole idempotence story.
    private var storage: [String: ReminderOccurrence] = [:]

    /// The last instant `materializeElapsedOccurrences` looked at. Callers can feed this straight
    /// back in as `since` on the next launch.
    private(set) var lastMaterializedAt: Date?

    var options: Options = Options()

    init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Reading

    /// Every occurrence on file, oldest first. Sorted so anything derived from it is deterministic.
    var occurrences: [ReminderOccurrence] {
        storage.values.sorted {
            $0.dueAt == $1.dueAt ? $0.id < $1.id : $0.dueAt < $1.dueAt
        }
    }

    var isEmpty: Bool { storage.isEmpty }
    var count: Int { storage.count }

    func occurrence(id: String) -> ReminderOccurrence? { storage[id] }

    func occurrence(reminderID: String, slotIndex: Int, dueAt: Date) -> ReminderOccurrence? {
        storage[ReminderOccurrence.makeID(reminderID: reminderID, slotIndex: slotIndex, dueAt: dueAt)]
    }

    /// Occurrences for one reminder (optionally one slot) inside a half-open window `[from, to)`.
    func occurrences(
        reminderID: String,
        slotIndex: Int? = nil,
        from: Date,
        to: Date
    ) -> [ReminderOccurrence] {
        occurrences.filter {
            $0.reminderID == reminderID
                && (slotIndex == nil || $0.slotIndex == slotIndex)
                && $0.dueAt >= from
                && $0.dueAt < to
        }
    }

    /// Occurrences across all reminders inside a half-open window `[from, to)`.
    func occurrences(from: Date, to: Date) -> [ReminderOccurrence] {
        occurrences.filter { $0.dueAt >= from && $0.dueAt < to }
    }

    // MARK: - Writing

    /// Inserts or merges one occurrence.
    ///
    /// Merging follows one rule: **a stronger signal never loses to a weaker one.** A recorded
    /// `.acknowledged` cannot be overwritten by a later materialization pass deciding it heard
    /// nothing. Told facts beat interactions, interactions beat silence, and a newer told fact
    /// replaces an older one because the user changed their mind out loud.
    @discardableResult
    mutating func record(_ occurrence: ReminderOccurrence) -> ReminderOccurrence {
        guard let existing = storage[occurrence.id] else {
            storage[occurrence.id] = occurrence
            return occurrence
        }
        let incoming = occurrence.outcome
        let current = existing.outcome

        let shouldReplace: Bool
        if incoming.signalStrength > current.signalStrength {
            shouldReplace = true
        } else if incoming.signalStrength == current.signalStrength {
            // Same strength: the later statement wins, and a higher snooze count always wins so a
            // replayed response cannot quietly decrement the count.
            shouldReplace = incoming.snoozeCount >= current.snoozeCount
        } else {
            shouldReplace = false
        }

        if shouldReplace {
            storage[occurrence.id] = occurrence
            return occurrence
        }
        return existing
    }

    /// The user tapped Done.
    ///
    /// `dueAt` is optional because a notification response does not always carry one. When it is
    /// missing we attach the tap to the most recent unresolved occurrence for that slot inside
    /// `responseMatchWindow`; failing that we create a row dated at the tap itself, because losing
    /// a told fact is strictly worse than an approximate timestamp on one.
    @discardableResult
    mutating func markAcknowledged(
        reminderID: String,
        slotIndex: Int,
        at date: Date,
        dueAt: Date? = nil
    ) -> ReminderOccurrence {
        let resolved = resolveDueAt(reminderID: reminderID, slotIndex: slotIndex, at: date, dueAt: dueAt)
        return record(
            ReminderOccurrence(
                reminderID: reminderID,
                slotIndex: slotIndex,
                dueAt: resolved,
                outcome: .acknowledged(at: date)
            )
        )
    }

    /// The user tapped Snooze. Increments the count when this occurrence was already snoozed.
    @discardableResult
    mutating func markSnoozed(
        reminderID: String,
        slotIndex: Int,
        at date: Date,
        dueAt: Date? = nil
    ) -> ReminderOccurrence {
        let resolved = resolveDueAt(reminderID: reminderID, slotIndex: slotIndex, at: date, dueAt: dueAt)
        let id = ReminderOccurrence.makeID(reminderID: reminderID, slotIndex: slotIndex, dueAt: resolved)
        let previousCount = storage[id]?.outcome.snoozeCount ?? 0
        return record(
            ReminderOccurrence(
                reminderID: reminderID,
                slotIndex: slotIndex,
                dueAt: resolved,
                outcome: .snoozed(count: previousCount + 1, lastAt: date)
            )
        )
    }

    /// The user told us this one slipped.
    ///
    /// The only path in the whole app that may produce a "missed" record, and it exists solely
    /// because the user said the words. Nothing infers this.
    @discardableResult
    mutating func markSkipped(
        reminderID: String,
        slotIndex: Int,
        at date: Date,
        dueAt: Date? = nil
    ) -> ReminderOccurrence {
        let resolved = resolveDueAt(reminderID: reminderID, slotIndex: slotIndex, at: date, dueAt: dueAt)
        return record(
            ReminderOccurrence(
                reminderID: reminderID,
                slotIndex: slotIndex,
                dueAt: resolved,
                outcome: .dismissedAsSkipped(at: date)
            )
        )
    }

    /// Forgets everything about one reminder. Called when a reminder is deleted, so an unapproved
    /// medication leaves no behavioural shadow behind.
    mutating func forget(reminderID: String) {
        storage = storage.filter { $0.value.reminderID != reminderID }
    }

    // MARK: - Materialization

    /// Turns "nothing happened" into rows.
    ///
    /// Walks each active reminder's approved times, works out which firings have already gone by
    /// without a recorded outcome, and records them as `.noResponse`.
    ///
    /// ## The three things that are easy to get wrong here
    ///
    /// 1. **Do not backfill before approval.** The scan floor for each reminder is its
    ///    `approvedAt`. A reminder approved this morning has no history, and inventing a fortnight
    ///    of silences for it would produce a check-in on day one accusing the user of ignoring
    ///    something that did not exist yet. This is the single most important line in the method.
    /// 2. **Do not race the user.** Occurrences inside `options.noResponseGrace` of now are left
    ///    alone; they are not silence yet, they are simply recent.
    /// 3. **Do not fabricate silence around a told fact.** If the user tapped Done and we could
    ///    not attach it to a precise due time, an approximate row exists nearby. Materializing the
    ///    exact-time row on top of it would leave one acknowledgement and one phantom silence for
    ///    the same real dose, and the phantom would feed the detector. So a due time with a told
    ///    fact within `responseMatchWindow` is skipped.
    ///
    /// Calendar arithmetic uses `Calendar.nextDate(after:matching:)` rather than adding 86,400
    /// seconds, so a DST change does not slide every subsequent occurrence by an hour and split
    /// the ledger into duplicates. Occurrences are computed in the user's current timezone because
    /// that is where the notification actually fires.
    ///
    /// Idempotent: running it twice returns rows the second time only if time has passed.
    ///
    /// - Parameters:
    ///   - reminders: the approved reminders. Inactive ones are skipped — a paused reminder never
    ///     fired, so it cannot have been ignored.
    ///   - since: earliest instant to consider. Clamped to the retention horizon, so passing
    ///     `.distantPast` is safe rather than explosive. Pass `lastMaterializedAt` on later runs.
    ///   - now: the clock, injected for testability.
    /// - Returns: the newly created `.noResponse` rows, oldest first.
    @discardableResult
    mutating func materializeElapsedOccurrences(
        for reminders: [ApprovedReminder],
        since: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> [ReminderOccurrence] {
        let horizon = now.addingTimeInterval(-options.retention)
        let floor = max(since, horizon)
        let cutoff = now.addingTimeInterval(-options.noResponseGrace)
        var created: [ReminderOccurrence] = []

        guard cutoff > floor else {
            lastMaterializedAt = now
            return []
        }

        for reminder in reminders where reminder.isActive {
            // (1) Never look at time before the user approved this reminder.
            let scanStart = max(floor, reminder.approvedAt)
            guard scanStart < cutoff else { continue }

            for (slotIndex, time) in reminder.times.enumerated() {
                guard let hour = time.hour, let minute = time.minute else { continue }
                let match = DateComponents(hour: hour, minute: minute)

                var cursor = scanStart
                // Bounded so a pathological calendar cannot spin forever. Retention in days, plus
                // slack for DST and leap seconds.
                let maximumSteps = Int(options.retention / (24 * 60 * 60)) + 4

                for _ in 0..<maximumSteps {
                    guard let due = calendar.nextDate(
                        after: cursor,
                        matching: match,
                        matchingPolicy: .nextTime,
                        direction: .forward
                    ) else { break }
                    // (2) Recent is not silent.
                    guard due <= cutoff else { break }
                    cursor = due

                    let id = ReminderOccurrence.makeID(
                        reminderID: reminder.id, slotIndex: slotIndex, dueAt: due
                    )
                    guard storage[id] == nil else { continue }
                    // (3) A told fact nearby means this dose is already accounted for.
                    guard !hasToldFact(reminderID: reminder.id, slotIndex: slotIndex, near: due) else { continue }

                    let occurrence = ReminderOccurrence(
                        reminderID: reminder.id,
                        slotIndex: slotIndex,
                        dueAt: due,
                        outcome: .noResponse
                    )
                    storage[id] = occurrence
                    created.append(occurrence)
                }
            }
        }

        lastMaterializedAt = now
        prune(now: now)
        return created.sorted { $0.dueAt == $1.dueAt ? $0.id < $1.id : $0.dueAt < $1.dueAt }
    }

    /// Convenience overload using the ledger's own high-water mark.
    ///
    /// A day of slack is subtracted so a gap can never be skipped: re-examining a window is free
    /// because ids are deterministic, whereas missing one is permanent.
    @discardableResult
    mutating func materializeElapsedOccurrences(
        for reminders: [ApprovedReminder],
        now: Date,
        calendar: Calendar = .current
    ) -> [ReminderOccurrence] {
        let since = lastMaterializedAt?.addingTimeInterval(-24 * 60 * 60)
            ?? now.addingTimeInterval(-options.retention)
        return materializeElapsedOccurrences(for: reminders, since: since, now: now, calendar: calendar)
    }

    // MARK: - Retention

    /// Drops anything older than `options.retention`. This is not an archive.
    @discardableResult
    mutating func prune(now: Date) -> Int {
        let horizon = now.addingTimeInterval(-options.retention)
        let before = storage.count
        storage = storage.filter { $0.value.dueAt >= horizon }
        return before - storage.count
    }

    // MARK: - Private

    /// Finds the due time a bare response belongs to.
    ///
    /// Prefers the most recent existing occurrence for that slot at or before the tap and within
    /// the match window. Falls back to the caller's `dueAt`, then to the tap time itself.
    private func resolveDueAt(
        reminderID: String,
        slotIndex: Int,
        at date: Date,
        dueAt: Date?
    ) -> Date {
        if let dueAt { return dueAt }
        let candidates = storage.values.filter {
            $0.reminderID == reminderID
                && $0.slotIndex == slotIndex
                && $0.dueAt <= date
                && date.timeIntervalSince($0.dueAt) <= options.responseMatchWindow
        }
        return candidates.max(by: { $0.dueAt < $1.dueAt })?.dueAt ?? date
    }

    private func hasToldFact(reminderID: String, slotIndex: Int, near due: Date) -> Bool {
        storage.values.contains {
            $0.reminderID == reminderID
                && $0.slotIndex == slotIndex
                && $0.outcome.isToldByUser
                && abs($0.dueAt.timeIntervalSince(due)) <= options.responseMatchWindow
        }
    }
}

/// Persistence wrapper for `OutcomeLedger`.
///
/// Main-actor because it is the thing the UI and the notification-response handler both touch, and
/// because it mirrors `VaultStore`'s contract: **a storage failure is surfaced, never thrown and
/// never fatal.** Not being able to write down that a reminder was snoozed is worth showing in
/// Settings; it is not worth interrupting somebody who is trying to take their medication.
///
/// The ledger itself stays a plain value type so `PatternDetector` can be exercised with no actor,
/// no vault, and no device.
@MainActor
final class OutcomeLedgerStore {
    private(set) var ledger: OutcomeLedger
    /// Most recent persistence failure, as a PHI-free description.
    private(set) var lastErrorDescription: String?
    private(set) var isLoaded = false

    private let vault: any AdherenceVaultPersisting
    private let fileName: String

    init(
        vault: any AdherenceVaultPersisting,
        fileName: String = AdherenceVaultFile.outcomeLedger,
        ledger: OutcomeLedger = OutcomeLedger()
    ) {
        self.vault = vault
        self.fileName = fileName
        self.ledger = ledger
    }

    /// Loads the ledger. A decode failure leaves an empty ledger rather than taking the app down;
    /// the worst case is that Remli forgets what it noticed, which is a recoverable kind of quiet.
    func load() {
        do {
            if let stored = try vault.read(OutcomeLedger.self, from: fileName) {
                ledger = stored
            }
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = "Could not read the reminder history: \(error)"
        }
        isLoaded = true
    }

    /// Mutates and persists in one step, so there is no code path that updates memory and forgets
    /// the disk.
    @discardableResult
    func update<T>(_ body: (inout OutcomeLedger) -> T) -> T {
        let result = body(&ledger)
        save()
        return result
    }

    func save() {
        do {
            try vault.write(ledger, to: fileName)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = "Could not save the reminder history: \(error)"
        }
    }

    /// Wipes the behavioural trace without touching the care record.
    func forgetEverythingNoticed() {
        ledger = OutcomeLedger(options: ledger.options)
        save()
    }
}
