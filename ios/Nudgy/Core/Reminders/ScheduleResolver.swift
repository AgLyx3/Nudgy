import Foundation

/// `DosingSchedule` → `[ProposedSlot]`.
///
/// ## The one rule that matters
///
/// A slot may only carry `.fromYourRecord` provenance for its time of day when the chart actually
/// stated a point in the day — that is, a `Timing.repeat.when` code such as `ACM` or `HS`. FHIR
/// almost never contains a clock time, and inventing one is clinical advice.
///
/// So **`timeOfDay` is nil on every record slot this resolver produces**, including the ones with
/// a `when` code. "Before breakfast" is not 7:00 AM; it is before breakfast. The `when` code
/// changes the slot's *provenance and label*, never its clock.
///
/// ## Convenience suggestions
///
/// Nudgy still wants to be useful, so each dose also gets a *paired* slot carrying a default clock
/// time with `.convenienceSuggestion(basis:)` provenance. The pair is the point: the UI can render
///
/// > Dose 1 of 2 — your record does not name a time. Nudgy suggests 8:00 AM.
///
/// which is distinguishable from both "no time known" and "the chart says 8:00 AM". A silent
/// default would collapse all three into one.
///
/// Slot identity encodes the pairing:
/// - record slot:     `<idPrefix>#slot<N>`
/// - paired suggestion: `<idPrefix>#slot<N>#suggested`
struct ScheduleResolver {

    /// Suffix marking the convenience-suggestion half of a slot pair.
    static let suggestionIDSuffix = "#suggested"

    struct Options {
        /// Default clock times Nudgy offers when the record names none. Pure UX defaults with no
        /// clinical meaning whatsoever.
        var oncePerDay: [DateComponents] = [Self.time(9, 0)]
        var twicePerDay: [DateComponents] = [Self.time(8, 0), Self.time(20, 0)]
        var threePerDay: [DateComponents] = [Self.time(8, 0), Self.time(14, 0), Self.time(20, 0)]
        var fourPerDay: [DateComponents] = [
            Self.time(8, 0), Self.time(12, 0), Self.time(16, 0), Self.time(20, 0)
        ]
        /// For five or more, spread evenly between these two hours.
        var spreadStartHour: Int = 8
        var spreadEndHour: Int = 22

        static func time(_ hour: Int, _ minute: Int) -> DateComponents {
            DateComponents(hour: hour, minute: minute)
        }

        init() {}
    }

    var options: Options

    init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - When codes

    /// A `Timing.repeat.when` code, its plain meaning, and the clock time Nudgy would *suggest*
    /// for it.
    ///
    /// The label is the code's defined meaning in the FHIR EventTiming value set — decoding the
    /// record's own wording, not adding to it. The suggested time is Nudgy's, and is only ever
    /// attached to a `.convenienceSuggestion` slot.
    struct WhenCodeMeaning: Hashable {
        let code: String
        let label: String
        let suggestedTime: DateComponents
    }

    static let whenCodeMeanings: [String: WhenCodeMeaning] = {
        let entries: [(String, String, Int, Int)] = [
            ("ACM",   "Before breakfast",   7, 0),
            ("ACD",   "Before lunch",      11, 30),
            ("ACV",   "Before dinner",     17, 30),
            ("AC",    "Before meals",       7, 30),
            ("PCM",   "After breakfast",    8, 30),
            ("PCD",   "After lunch",       13, 0),
            ("PCV",   "After dinner",      19, 0),
            ("PC",    "After meals",        8, 30),
            ("HS",    "At bedtime",        22, 0),
            ("WAKE",  "On waking",          7, 0),
            ("MORN",  "In the morning",     8, 0),
            ("NOON",  "At midday",         12, 0),
            ("AFT",   "In the afternoon",  15, 0),
            ("EVE",   "In the evening",    19, 0),
            ("NIGHT", "At night",          21, 0)
        ]
        return Dictionary(uniqueKeysWithValues: entries.map { code, label, hour, minute in
            (code, WhenCodeMeaning(
                code: code,
                label: label,
                suggestedTime: DateComponents(hour: hour, minute: minute)
            ))
        })
    }()

    static func meaning(forWhenCode code: String) -> WhenCodeMeaning? {
        whenCodeMeanings[code.uppercased().trimmingCharacters(in: .whitespaces)]
    }

    // MARK: - Resolution

    /// - Parameters:
    ///   - schedule: the cadence the record stated.
    ///   - scheduleCitation: citation for `timing.repeat`. Required before any `when` code can be
    ///     honoured — a record-sourced time with no citation is not something Nudgy will show.
    ///   - idPrefix: usually the proposal id, so slot ids are stable across imports.
    ///   - unitNoun: "dose" for medication, "session" for therapy.
    func slots(
        for schedule: DosingSchedule,
        scheduleCitation: SourceCitation?,
        idPrefix: String,
        unitNoun: String = "dose"
    ) -> [ProposedSlot] {
        let dailyCount = schedule.timesPerDay
        let count = max(dailyCount ?? schedule.frequency, 1)
        let defaults = dailyCount != nil ? Self.defaultClockTimes(perDay: count, options: options) : []

        var slots: [ProposedSlot] = []
        for index in 0..<count {
            // A `when` code is only usable when it is both recognized and citable.
            let rawWhen: String? = index < schedule.whenCodes.count ? schedule.whenCodes[index] : nil
            let meaning: WhenCodeMeaning? = {
                guard let rawWhen, scheduleCitation != nil else { return nil }
                return Self.meaning(forWhenCode: rawWhen)
            }()

            let label: String
            if let meaning {
                label = meaning.label
            } else if count == 1 {
                label = "Daily \(unitNoun)"
            } else {
                label = "\(unitNoun.capitalizedFirst) \(index + 1) of \(count)"
            }

            // --- Record slot: never carries a clock time. ---
            let provenance: Provenance
            if meaning != nil, let base = scheduleCitation, let rawWhen {
                provenance = .fromYourRecord(
                    SourceCitation(
                        sourceLabel: base.sourceLabel,
                        resourceType: base.resourceType,
                        resourceID: base.resourceID,
                        fieldPath: "\(base.fieldPath).when[\(index)]",
                        verbatimText: rawWhen,
                        recordedDate: base.recordedDate,
                        dataOrigin: base.dataOrigin
                    )
                )
            } else {
                provenance = .needsReview(.timeOfDayNotSpecified)
            }

            slots.append(
                ProposedSlot(
                    id: "\(idPrefix)#slot\(index)",
                    timeOfDay: nil,
                    provenance: provenance,
                    label: label
                )
            )

            // --- Paired convenience suggestion. ---
            let suggested: DateComponents?
            let basis: String
            if let meaning {
                suggested = meaning.suggestedTime
                basis = "Nudgy's own default clock time for a reminder labelled “\(meaning.label)”. "
                    + "Your record names the point in the day, not a clock time. "
                    + "This is a scheduling idea, not health guidance."
            } else if index < defaults.count {
                suggested = defaults[index]
                basis = "Nudgy's own default spacing for \(count) reminder\(count == 1 ? "" : "s") a day. "
                    + "Your record does not name a time of day. "
                    + "This is a scheduling idea, not health guidance."
            } else {
                suggested = nil
                basis = ""
            }

            if let suggested {
                slots.append(
                    ProposedSlot(
                        id: "\(idPrefix)#slot\(index)\(Self.suggestionIDSuffix)",
                        timeOfDay: suggested,
                        provenance: .convenienceSuggestion(basis: basis),
                        label: label
                    )
                )
            }
        }
        return slots
    }

    // MARK: - Defaults

    /// Nudgy's own clock times. Nothing here is derived from the record, the drug, or anything
    /// clinical — it is spacing that looks reasonable on a phone.
    static func defaultClockTimes(perDay: Int, options: Options = Options()) -> [DateComponents] {
        switch perDay {
        case ..<1: return []
        case 1: return options.oncePerDay
        case 2: return options.twicePerDay
        case 3: return options.threePerDay
        case 4: return options.fourPerDay
        default:
            let startMinutes = options.spreadStartHour * 60
            let endMinutes = options.spreadEndHour * 60
            let step = Double(endMinutes - startMinutes) / Double(perDay - 1)
            return (0..<perDay).map { index in
                let total = startMinutes + Int((Double(index) * step).rounded())
                return DateComponents(hour: total / 60, minute: total % 60)
            }
        }
    }

    // MARK: - Slot pairing helpers

    static func isConvenienceSuggestion(_ slot: ProposedSlot) -> Bool {
        if case .convenienceSuggestion = slot.provenance { return true }
        return false
    }

    /// The record slot a suggestion belongs to, or nil when `slot` is not a suggestion.
    static func pairedRecordSlotID(for slot: ProposedSlot) -> String? {
        guard slot.id.hasSuffix(suggestionIDSuffix) else { return nil }
        return String(slot.id.dropLast(suggestionIDSuffix.count))
    }

    /// The slots a UI should show as "what the record actually says".
    static func recordSlots(in slots: [ProposedSlot]) -> [ProposedSlot] {
        slots.filter { !isConvenienceSuggestion($0) }
    }

    static func suggestionSlots(in slots: [ProposedSlot]) -> [ProposedSlot] {
        slots.filter { isConvenienceSuggestion($0) }
    }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
