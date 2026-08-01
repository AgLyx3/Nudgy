import Foundation

/// Everything needed to build a `SourceCitation` for one FHIR resource.
///
/// Shared by `DosageInstructionParser` and `TherapyTaskParser`. It exists so a parser can never
/// produce a clinical value without also being able to say exactly where it came from — the
/// parser is handed the citation identity up front rather than inventing one later.
struct CitationContext: Hashable {
    let sourceLabel: String
    let resourceType: String
    let resourceID: String
    let recordedDate: Date?
    let dataOrigin: DataOrigin

    func citation(path: String, verbatim: String) -> SourceCitation {
        SourceCitation(
            sourceLabel: sourceLabel,
            resourceType: resourceType,
            resourceID: resourceID,
            fieldPath: path,
            verbatimText: verbatim,
            recordedDate: recordedDate,
            dataOrigin: dataOrigin
        )
    }
}

/// Turns a FHIR `Dosage` into the fields Nudgy is willing to state, each with a citation.
///
/// The hard rules this file implements:
///
/// - An unrecognized `periodUnit` produces **no schedule at all**. A wrong cadence is worse than
///   no cadence, so there is no fallback guess.
/// - `frequency` and `period` must both be present. FHIR defines a default of 1 for `frequency`;
///   Nudgy does not apply it, because "the spec says assume once" is still an assumption about a
///   medication.
/// - Food instructions are stored as the **verbatim substring the record used**. There is no
///   `enum FoodTiming { withFood, withoutFood }` anywhere in this codebase, because normalizing
///   "with or after food" into `.withFood` silently discards "or after".
/// - `asNeededBoolean` is carried through untouched. The proposal engine refuses to schedule on
///   it, so losing it would be a safety failure rather than a cosmetic one.
struct DosageInstructionParser {

    /// The result of reading one `Dosage` element.
    struct ParsedDosage: Hashable {
        /// Verbatim `dosageInstruction.text` / `dosage.text`, when the record has one.
        /// Synthea usually does not.
        var verbatimText: String?
        var instructionCitation: SourceCitation?

        var schedule: DosingSchedule?
        var scheduleCitation: SourceCitation?

        /// Only ever the record's own words. Never a normalized category.
        var foodInstruction: FoodInstruction?

        var route: String?
        var routeCitation: SourceCitation?

        /// Faithful to `asNeededBoolean`. Defaults to false only when the record omits it.
        var isAsNeeded: Bool = false

        /// Set when `timing.repeat` carried a `periodUnit` Nudgy does not recognize. The schedule
        /// is nil in that case; this field lets the UI say so instead of staying silent.
        var unrecognizedPeriodUnit: String?

        /// True when the record supplied nothing Nudgy can turn into a cadence.
        var hasNoUsableSchedule: Bool { schedule == nil }
    }

    init() {}

    // MARK: - Parsing

    /// - Parameters:
    ///   - dosage: the `Dosage` element, or nil when the resource has none at all.
    ///   - fieldPathPrefix: e.g. `dosageInstruction[0]` or `dosage[0]`. Citations are built by
    ///     appending to this, so the resulting `fieldPath` points at the real element.
    ///   - context: citation identity for the owning resource.
    func parse(
        _ dosage: FHIRDosage?,
        fieldPathPrefix: String,
        context: CitationContext
    ) -> ParsedDosage {
        var parsed = ParsedDosage()
        guard let dosage else { return parsed }

        parsed.isAsNeeded = dosage.asNeededBoolean ?? false

        // Verbatim instruction text.
        if let text = dosage.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            parsed.verbatimText = text
            parsed.instructionCitation = context.citation(path: "\(fieldPathPrefix).text", verbatim: text)
        }

        // Route.
        if let route = dosage.route?.bestDisplay?.trimmingCharacters(in: .whitespacesAndNewlines),
           !route.isEmpty {
            parsed.route = route
            parsed.routeCitation = context.citation(
                path: "\(fieldPathPrefix).route.text",
                verbatim: route
            )
        }

        // Cadence.
        if let repeatElement = dosage.timing?.repeatElement {
            let (schedule, citation, unknownUnit) = parseSchedule(
                repeatElement,
                fieldPathPrefix: "\(fieldPathPrefix).timing.repeat",
                context: context
            )
            parsed.schedule = schedule
            parsed.scheduleCitation = citation
            parsed.unrecognizedPeriodUnit = unknownUnit
        }

        // Food instruction.
        parsed.foodInstruction = parseFoodInstruction(
            dosage,
            fieldPathPrefix: fieldPathPrefix,
            context: context
        )

        return parsed
    }

    /// Reads a `Timing.repeat`. Shared with `TherapyTaskParser`, whose `scheduledTiming` has the
    /// same shape.
    func parseSchedule(
        _ repeatElement: FHIRTimingRepeat,
        fieldPathPrefix: String,
        context: CitationContext
    ) -> (schedule: DosingSchedule?, citation: SourceCitation?, unrecognizedPeriodUnit: String?) {
        guard let rawUnit = repeatElement.periodUnit else {
            return (nil, nil, nil)
        }
        guard let unit = DosingSchedule.PeriodUnit(rawValue: rawUnit) else {
            // Unknown unit: no schedule, and say which unit was not understood.
            return (nil, nil, rawUnit)
        }
        // Both must be stated. Nudgy does not apply FHIR's implicit `frequency` default of 1.
        guard let frequency = repeatElement.frequency, let period = repeatElement.period else {
            return (nil, nil, nil)
        }

        let whenCodes = (repeatElement.when ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let schedule = DosingSchedule(
            frequency: frequency,
            period: period,
            periodUnit: unit,
            whenCodes: whenCodes
        )

        let citation = context.citation(
            path: fieldPathPrefix,
            verbatim: Self.repeatVerbatim(schedule)
        )
        return (schedule, citation, nil)
    }

    /// Renders a `Timing.repeat` element the way the record holds it. Used for citation text, so
    /// that expanding a "how often" chip shows the structured field rather than Nudgy's prose.
    static func repeatVerbatim(_ schedule: DosingSchedule) -> String {
        var verbatim = "frequency \(schedule.frequency)"
            + ", period \(format(schedule.period))"
            + ", periodUnit \"\(schedule.periodUnit.rawValue)\""
        if !schedule.whenCodes.isEmpty {
            verbatim += ", when [\(schedule.whenCodes.joined(separator: ", "))]"
        }
        return verbatim
    }

    // MARK: - Food instructions

    /// Phrases that mark a food or administration instruction. Matched case-insensitively and
    /// longest-first so "with or after food" is never truncated to "after food".
    ///
    /// This list decides *where to look*. It never decides *what to say* — the stored value is
    /// always the record's own characters.
    static let foodPhrases: [String] = [
        "on an empty stomach",
        "with a full glass of water",
        "immediately after food",
        "immediately before food",
        "with or after food",
        "with or after meals",
        "before breakfast",
        "after breakfast",
        "with breakfast",
        "before lunch",
        "after lunch",
        "with lunch",
        "before dinner",
        "after dinner",
        "with dinner",
        "before supper",
        "after supper",
        "with supper",
        "before meals",
        "after meals",
        "with each meal",
        "with a meal",
        "with meals",
        "empty stomach",
        "without food",
        "before food",
        "after food",
        "with food",
        "before eating",
        "after eating",
        "while eating"
    ]

    private static let sortedFoodPhrases: [String] =
        foodPhrases.sorted { $0.count > $1.count }

    /// True when the text literally contains one of the food phrases.
    static func mentionsFood(_ text: String) -> Bool {
        firstFoodPhraseRange(in: text) != nil
    }

    /// The range of the first food phrase in `text`, in the *original* string, so the caller can
    /// slice out the untouched characters rather than the lowercased ones.
    static func firstFoodPhraseRange(in text: String) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for phrase in sortedFoodPhrases {
            guard let range = text.range(of: phrase, options: [.caseInsensitive]) else { continue }
            if let current = best {
                // Prefer the earliest occurrence; ties go to the longer phrase, which the sort
                // order already guarantees.
                if range.lowerBound < current.lowerBound { best = range }
            } else {
                best = range
            }
        }
        return best
    }

    private func parseFoodInstruction(
        _ dosage: FHIRDosage,
        fieldPathPrefix: String,
        context: CitationContext
    ) -> FoodInstruction? {
        // 1. `additionalInstruction` is a dedicated field for this, so its whole text is the
        //    instruction. Store all of it — "On an empty stomach, 30 to 60 minutes before
        //    breakfast" would lose its meaning trimmed to "on an empty stomach".
        for (index, concept) in (dosage.additionalInstruction ?? []).enumerated() {
            if let text = concept.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty,
               Self.mentionsFood(text) {
                return FoodInstruction(
                    verbatim: text,
                    citation: context.citation(
                        path: "\(fieldPathPrefix).additionalInstruction[\(index)].text",
                        verbatim: text
                    )
                )
            }
            for (codingIndex, coding) in (concept.coding ?? []).enumerated() {
                guard let display = coding.display?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !display.isEmpty,
                      Self.mentionsFood(display) else { continue }
                return FoodInstruction(
                    verbatim: display,
                    citation: context.citation(
                        path: "\(fieldPathPrefix).additionalInstruction[\(index)].coding[\(codingIndex)].display",
                        verbatim: display
                    )
                )
            }
        }

        // 2. Otherwise look inside the free-text instruction, and keep only the matched substring
        //    exactly as the record wrote it. The citation carries the whole sentence, so the UI
        //    can always show the phrase in the context the clinician wrote it in.
        if let text = dosage.text, let range = Self.firstFoodPhraseRange(in: text) {
            let substring = String(text[range])
            return FoodInstruction(
                verbatim: substring,
                citation: context.citation(
                    path: "\(fieldPathPrefix).text",
                    verbatim: text
                )
            )
        }

        return nil
    }

    // MARK: - Helpers

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}
