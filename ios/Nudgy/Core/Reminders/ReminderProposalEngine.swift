import Foundation

/// `CareRecordSnapshot` → `[ReminderProposal]`.
///
/// This is the component that must never invent clinical advice, so every sentence it produces is
/// either a quotation from the record or a statement about what the record does *not* say.
///
/// The rules it enforces, and where:
///
/// | Design doc rule | Enforced by |
/// |---|---|
/// | Every proposal cites its source | `medicationFacts` / `therapyFacts` — a fact cannot be built without a `SourceCitation` |
/// | Never invent timing or food instructions | `ScheduleResolver` (nil `timeOfDay`), and no code path here writes a food string |
/// | Convenience windows must be labelled | `.convenienceSuggestion(basis:)` slots, never `.fromYourRecord` |
/// | As-needed medications get no schedule | `declinedReason` → `.asNeededMedication`, slots left empty |
/// | One source has a food instruction, another does not → possible concern | `conflictFlags(for:)` |
/// | Close reminder times → notification-management options, not medical advice | `clusterFlags(for:)` |
/// | Individual approval for every reminder | `ReminderProposal.requiresIndividualApproval` |
/// | PT reminders cite name / frequency / reps / equipment / position, and ask for confirmation when missing | `therapyFacts` + `therapyGapFlags` |
struct ReminderProposalEngine {

    struct Options {
        /// Reminders within this window of each other trigger the notification-management offer.
        var clusterWindowMinutes: Int = 30
        /// A cluster needs at least this many distinct proposals to be worth mentioning.
        var minimumClusterSize: Int = 2

        init() {}
    }

    var options: Options
    var resolver: ScheduleResolver

    init(options: Options = Options(), resolver: ScheduleResolver = ScheduleResolver()) {
        self.options = options
        self.resolver = resolver
    }

    // MARK: - Entry point

    /// - Parameter skippedProposalIDs: proposal ids the user has already dismissed. Because
    ///   proposal ids are derived from resource identity rather than a fresh UUID, a re-import of
    ///   the same chart produces the same ids and skipped items stay skipped.
    func proposals(
        from snapshot: CareRecordSnapshot,
        skippedProposalIDs: Set<String> = []
    ) -> [ReminderProposal] {

        // Conflicts are a fact about the record, so they are computed across *all* medications in
        // the snapshot — including any whose own proposal the user skipped.
        let conflicts = conflictFlags(across: snapshot.medications)

        var drafts: [Draft] = []
        for item in snapshot.medications {
            let id = Self.proposalID(forMedication: item)
            guard !skippedProposalIDs.contains(id) else { continue }
            drafts.append(medicationDraft(for: item, id: id, conflictFlags: conflicts[item.id] ?? []))
        }
        for task in snapshot.therapyTasks {
            let id = Self.proposalID(forTherapy: task)
            guard !skippedProposalIDs.contains(id) else { continue }
            drafts.append(therapyDraft(for: task, id: id))
        }

        // Clustering only considers what the user will actually be offered.
        let clusters = clusterFlags(for: drafts)

        return drafts.map { draft in
            ReminderProposal(
                id: draft.id,
                kind: draft.kind,
                title: draft.title,
                subtitle: draft.subtitle,
                sourceFacts: draft.facts,
                slots: draft.slots,
                flags: draft.flags + (clusters[draft.id] ?? []),
                primaryProvenance: draft.primaryProvenance,
                sourceLabel: draft.sourceLabel,
                dataOrigin: draft.dataOrigin,
                schedulingDeclinedReason: draft.declinedReason
            )
        }
    }

    // MARK: - Stable identity

    /// Derived from the FHIR resource identity, never from a UUID, so approve/skip state survives
    /// a re-import.
    static func proposalID(forMedication item: MedicationItem) -> String {
        "nudgy.proposal.medication.\(item.id)"
    }

    static func proposalID(forTherapy task: TherapyTask) -> String {
        "nudgy.proposal.therapy.\(task.id)"
    }

    // MARK: - Draft

    private struct Draft {
        var id: String
        var kind: ReminderKind
        var title: String
        var subtitle: String?
        var facts: [SourceFact]
        var slots: [ProposedSlot]
        var flags: [ProposalFlag]
        var primaryProvenance: Provenance
        var sourceLabel: String
        var dataOrigin: DataOrigin
        var declinedReason: ReviewReason?
    }

    // MARK: - Medication proposals

    private func medicationDraft(
        for item: MedicationItem,
        id: String,
        conflictFlags: [ProposalFlag]
    ) -> Draft {
        var facts = medicationFacts(for: item)
        var flags = conflictFlags
        var slots: [ProposedSlot] = []
        var declined: ReviewReason?

        if item.isAsNeeded {
            // The single most important refusal in the product.
            declined = .asNeededMedication
            let citation = item.instructionCitation ?? item.nameCitation
            flags.append(
                ProposalFlag(
                    severity: .info,
                    title: "No repeating reminder for this one",
                    detail: "Your record lists this medication as taken only when needed, "
                        + "so Nudgy is not proposing a repeating time for it.",
                    citations: [citation],
                    suggestedAction: "You can ask Nudgy for a one-off reminder whenever you want one."
                )
            )
        } else if let schedule = item.schedule {
            slots = resolver.slots(
                for: schedule,
                scheduleCitation: item.scheduleCitation,
                idPrefix: id,
                unitNoun: "dose"
            )
            if !schedule.whenCodes.isEmpty {
                let known = schedule.whenCodes.compactMap { ScheduleResolver.meaning(forWhenCode: $0) }
                if !known.isEmpty, let citation = item.scheduleCitation {
                    facts.append(
                        SourceFact(
                            label: "When in the day",
                            verbatim: known.map(\.label).joined(separator: ", "),
                            citation: citation
                        )
                    )
                }
            }
            if slots.allSatisfy({ $0.timeOfDay == nil }),
               schedule.whenCodes.isEmpty {
                flags.append(
                    ProposalFlag(
                        severity: .info,
                        title: "Your record does not name a time of day",
                        detail: "Your chart says this is \(schedule.plainLanguage). "
                            + "It does not say what time of day. "
                            + "Nudgy has suggested clock times of its own, marked as suggestions, "
                            + "and can remind you then if that matches your routine.",
                        citations: [item.scheduleCitation].compactMap { $0 },
                        suggestedAction: "You can set the times yourself before approving this reminder."
                    )
                )
            }
        } else {
            declined = .frequencyNotSpecified
            flags.append(
                ProposalFlag(
                    severity: .info,
                    title: "Not enough in your record to set a time",
                    detail: "Your record lists this medication but does not say how often it is taken, "
                        + "so Nudgy is not proposing a schedule for it.",
                    citations: [item.nameCitation],
                    suggestedAction: "Your care team or pharmacy can confirm how often this one is taken."
                )
            )
        }

        let primary: Provenance
        if let declined {
            primary = .needsReview(declined)
        } else {
            primary = .fromYourRecord(item.instructionCitation ?? item.scheduleCitation ?? item.nameCitation)
        }

        return Draft(
            id: id,
            kind: .medication,
            title: item.conversationalName,
            subtitle: "\(item.sourceLabel) · \(item.dataOrigin.shortLabel)",
            facts: facts,
            slots: slots,
            flags: flags,
            primaryProvenance: primary,
            sourceLabel: item.sourceLabel,
            dataOrigin: item.dataOrigin,
            declinedReason: declined
        )
    }

    /// Everything Nudgy is willing to state about a medication, quoted, with citations.
    private func medicationFacts(for item: MedicationItem) -> [SourceFact] {
        var facts: [SourceFact] = [
            SourceFact(label: "Medication", verbatim: item.displayName, citation: item.nameCitation)
        ]
        if let text = item.instructionText, let citation = item.instructionCitation {
            facts.append(SourceFact(label: "Instruction", verbatim: text, citation: citation))
        }
        // Deliberately omitted for as-needed medications. FHIR's `timing.repeat` on a PRN order is
        // a ceiling, not a routine — restating "every 6 hours as needed for pain" as
        // "four times daily" would turn a limit into an instruction.
        if !item.isAsNeeded, let schedule = item.schedule, let citation = item.scheduleCitation {
            facts.append(
                SourceFact(label: "How often", verbatim: schedule.plainLanguage, citation: citation)
            )
        }
        if let food = item.foodInstruction {
            facts.append(
                SourceFact(label: "Food instruction", verbatim: food.verbatim, citation: food.citation)
            )
        }
        if item.isAsNeeded, item.instructionText == nil {
            // No written instruction to quote, so the as-needed flag itself is the cited fact.
            facts.append(
                SourceFact(
                    label: "Only when needed",
                    verbatim: "asNeededBoolean: true",
                    citation: item.nameCitation
                )
            )
        }
        return facts
    }

    // MARK: - Conflict detection (never resolution)

    /// Groups medications by drug and flags the pairs whose food instructions disagree.
    ///
    /// Nudgy states the discrepancy and shows both records verbatim with both citations. It does
    /// not decide which one is current, and it does not merge them — deciding would be a clinical
    /// judgement, and this engine does not make those.
    ///
    /// - Returns: flags keyed by `MedicationItem.id`.
    func conflictFlags(across medications: [MedicationItem]) -> [String: [ProposalFlag]] {
        var byDrug: [String: [MedicationItem]] = [:]
        for item in medications {
            byDrug[item.reconciliationKey, default: []].append(item)
        }

        var result: [String: [ProposalFlag]] = [:]
        for (_, group) in byDrug where group.count > 1 {
            for indexA in group.indices {
                for indexB in group.indices where indexB > indexA {
                    let a = group[indexA]
                    let b = group[indexB]
                    guard a.sourceLabel != b.sourceLabel else { continue }
                    guard foodInstructionsDisagree(a, b) else { continue }

                    let flag = ProposalFlag(
                        severity: .possibleConcern,
                        title: "Two of your records describe this differently",
                        detail: conflictDetail(a, b),
                        citations: conflictCitations(a, b),
                        suggestedAction: "Your care team or pharmacy can confirm which of these is current."
                    )
                    result[a.id, default: []].append(flag)
                    result[b.id, default: []].append(flag)
                }
            }
        }
        return result
    }

    private func foodInstructionsDisagree(_ a: MedicationItem, _ b: MedicationItem) -> Bool {
        switch (a.foodInstruction, b.foodInstruction) {
        case (nil, nil):
            return false
        case (nil, _), (_, nil):
            return true
        case (let left?, let right?):
            return left.verbatim.compare(right.verbatim, options: [.caseInsensitive]) != .orderedSame
        }
    }

    private func conflictDetail(_ a: MedicationItem, _ b: MedicationItem) -> String {
        func describe(_ item: MedicationItem) -> String {
            if let text = item.instructionText {
                return "Your record from \(item.sourceLabel) says: “\(text)”"
            }
            if let food = item.foodInstruction {
                return "Your record from \(item.sourceLabel) says: “\(food.verbatim)”"
            }
            return "Your record from \(item.sourceLabel) lists this medication with no written instruction."
        }

        func foodNote(_ item: MedicationItem) -> String {
            if let food = item.foodInstruction {
                return "\(item.sourceLabel) records a food instruction: “\(food.verbatim)”."
            }
            return "\(item.sourceLabel) records no food instruction."
        }

        return [
            describe(a),
            describe(b),
            foodNote(a),
            foodNote(b),
            "Nudgy does not know which of these is current, and will not choose between them."
        ].joined(separator: " ")
    }

    private func conflictCitations(_ a: MedicationItem, _ b: MedicationItem) -> [SourceCitation] {
        var citations: [SourceCitation] = []
        citations.append(a.foodInstruction?.citation ?? a.instructionCitation ?? a.nameCitation)
        citations.append(b.foodInstruction?.citation ?? b.instructionCitation ?? b.nameCitation)
        return citations
    }

    // MARK: - Therapy proposals

    private func therapyDraft(for task: TherapyTask, id: String) -> Draft {
        let facts = therapyFacts(for: task)
        var flags = therapyGapFlags(for: task)
        var slots: [ProposedSlot] = []
        var declined: ReviewReason?

        if let schedule = task.schedule {
            slots = resolver.slots(
                for: schedule,
                scheduleCitation: task.citation,
                idPrefix: id,
                unitNoun: "session"
            )
            if schedule.whenCodes.isEmpty {
                flags.append(
                    ProposalFlag(
                        severity: .info,
                        title: "Your record does not name a time of day",
                        detail: "Your chart says this is \(schedule.plainLanguage). "
                            + "It does not say what time of day. "
                            + "Nudgy has suggested clock times of its own, marked as suggestions, "
                            + "and can remind you then if that matches your routine.",
                        citations: [task.citation],
                        suggestedAction: "You can set the times yourself before approving this reminder."
                    )
                )
            }
        } else {
            declined = .frequencyNotSpecified
            flags.append(
                ProposalFlag(
                    severity: .info,
                    title: "Not enough in your record to set a time",
                    detail: "Your record names this exercise but does not say how often to do it, "
                        + "so Nudgy is not proposing a schedule for it.",
                    citations: [task.citation],
                    suggestedAction: "Your care team can confirm how often this exercise belongs in your day."
                )
            )
        }

        let primary: Provenance = declined.map { Provenance.needsReview($0) }
            ?? .fromYourRecord(task.citation)

        return Draft(
            id: id,
            kind: .therapy,
            title: task.exerciseName,
            subtitle: [task.planTitle, "\(task.sourceLabel) · \(task.dataOrigin.shortLabel)"]
                .compactMap { $0 }
                .joined(separator: " · "),
            facts: facts,
            slots: slots,
            flags: flags,
            primaryProvenance: primary,
            sourceLabel: task.sourceLabel,
            dataOrigin: task.dataOrigin,
            declinedReason: declined
        )
    }

    /// The design doc's required PT fields: exercise name, frequency, duration or repetitions,
    /// equipment if explicitly stated, body position if explicitly stated. Each is emitted only
    /// when the record supplies it, and always as the record's own words.
    private func therapyFacts(for task: TherapyTask) -> [SourceFact] {
        var facts: [SourceFact] = [
            SourceFact(
                label: "Exercise",
                verbatim: task.exerciseName,
                citation: activityCitation(task, field: "code.text", verbatim: task.exerciseName)
            )
        ]
        if let text = task.instructionText {
            let citation = activityCitation(task, field: "description", verbatim: text)
            facts.append(SourceFact(label: "How to do it", verbatim: text, citation: citation))
            if let position = TherapyTaskParser.bodyPositionSentence(in: text) {
                facts.append(SourceFact(label: "Body position", verbatim: position, citation: citation))
            }
        }
        if let schedule = task.schedule {
            facts.append(
                SourceFact(
                    label: "How often",
                    verbatim: schedule.plainLanguage,
                    citation: activityCitation(
                        task,
                        field: "scheduledTiming.repeat",
                        verbatim: DosageInstructionParser.repeatVerbatim(schedule)
                    )
                )
            )
        }
        if let quantity = task.quantityDescription {
            facts.append(
                SourceFact(
                    label: "How many",
                    verbatim: quantity,
                    citation: activityCitation(task, field: "quantity", verbatim: quantity)
                )
            )
        } else if let text = task.instructionText,
                  let phrase = TherapyTaskParser.repetitionOrDurationPhrase(in: text) {
            facts.append(
                SourceFact(
                    label: "How many",
                    verbatim: phrase,
                    citation: activityCitation(task, field: "description", verbatim: text)
                )
            )
        }
        if let equipment = task.equipmentMentioned, let text = task.instructionText {
            facts.append(
                SourceFact(
                    label: "Equipment named",
                    verbatim: equipment,
                    citation: activityCitation(task, field: "description", verbatim: text)
                )
            )
        }
        // The care plan title is context rather than a clinical claim, so it lives in the subtitle.
        // It is not emitted as a `SourceFact` because `TherapyTask` carries no citation for the
        // plan-level field it came from, and a fact with an inaccurate `fieldPath` is worse than
        // no fact.
        return facts
    }

    /// Builds a citation for a specific field of the care-plan activity this task came from.
    ///
    /// `TherapyTask` has a single citation slot, but the fields Nudgy quotes come from different
    /// elements of the same activity. This rewrites the field path off the activity prefix already
    /// present in `task.citation` (`activity[2].detail.description` → `activity[2].detail`) so every
    /// fact points at the element it was actually read from.
    private func activityCitation(
        _ task: TherapyTask,
        field: String,
        verbatim: String
    ) -> SourceCitation {
        let base = task.citation
        let prefix: String
        if let range = base.fieldPath.range(of: ".detail") {
            prefix = String(base.fieldPath[..<range.upperBound])
        } else {
            prefix = base.fieldPath
        }
        return SourceCitation(
            sourceLabel: base.sourceLabel,
            resourceType: base.resourceType,
            resourceID: base.resourceID,
            fieldPath: "\(prefix).\(field)",
            verbatimText: verbatim,
            recordedDate: base.recordedDate,
            dataOrigin: base.dataOrigin
        )
    }

    private func therapyGapFlags(for task: TherapyTask) -> [ProposalFlag] {
        var flags: [ProposalFlag] = []
        for gap in task.detailGaps {
            switch gap {
            case .therapyDetailIncomplete:
                flags.append(
                    ProposalFlag(
                        severity: .possibleConcern,
                        title: "Your record does not describe how to do this",
                        detail: "Your record names “\(task.exerciseName)” but does not describe the "
                            + "movement, the repetitions, or how long to hold it. "
                            + "Nudgy will not fill those in.",
                        citations: [task.citation],
                        suggestedAction: "Please confirm the details with your care team before you approve this reminder."
                    )
                )
            case .equipmentUnclear:
                flags.append(
                    ProposalFlag(
                        severity: .info,
                        title: "Your record does not name any equipment",
                        detail: "Nothing in the written instruction names equipment for this exercise. "
                            + "That is not the same as saying none is needed — Nudgy only reports what "
                            + "the record states.",
                        citations: [task.citation],
                        suggestedAction: "You can confirm with your care team what this exercise needs."
                    )
                )
            case .frequencyNotSpecified:
                // Reported through `schedulingDeclinedReason` and its own flag.
                continue
            case .timeOfDayNotSpecified, .asNeededMedication, .conflictingFoodInstruction, .remindersCluster:
                continue
            }
        }
        return flags
    }

    // MARK: - Clustering (a notification offer, never medical advice)

    /// Finds proposals whose *suggested* times land within the cluster window and offers the user
    /// notification-management options.
    ///
    /// Explicitly framed as a phone decision. Nudgy never says anything about whether taking
    /// things together is a good idea.
    private func clusterFlags(for drafts: [Draft]) -> [String: [ProposalFlag]] {
        struct Point {
            let draftIndex: Int
            let minutes: Int
        }

        var points: [Point] = []
        for (index, draft) in drafts.enumerated() {
            for slot in draft.slots {
                guard let suggested = slot.suggestion?.clockTime,
                      let hour = suggested.hour, let minute = suggested.minute else { continue }
                points.append(Point(draftIndex: index, minutes: hour * 60 + minute))
            }
        }
        guard points.count > 1 else { return [:] }
        points.sort { $0.minutes < $1.minutes }

        var result: [String: [ProposalFlag]] = [:]
        var start = 0
        var consumed = Set<Int>()

        while start < points.count {
            var end = start
            while end + 1 < points.count,
                  points[end + 1].minutes - points[start].minutes <= options.clusterWindowMinutes {
                end += 1
            }
            let window = points[start...end]
            let distinct = orderedUnique(window.map(\.draftIndex))
            if distinct.count >= options.minimumClusterSize, !consumed.contains(start) {
                let anchor = window.first!.minutes
                // Two records for the same drug produce the same title, so disambiguate by source
                // rather than showing the same name twice.
                var titleCounts: [String: Int] = [:]
                for index in distinct { titleCounts[drafts[index].title, default: 0] += 1 }
                let names = distinct.map { index -> String in
                    let draft = drafts[index]
                    return (titleCounts[draft.title] ?? 0) > 1
                        ? "\(draft.title) (\(draft.sourceLabel))"
                        : draft.title
                }
                let flag = ProposalFlag(
                    severity: .info,
                    title: "Nudgy's suggested times cluster around \(Self.clockText(minutes: anchor))",
                    detail: "\(Self.list(names)) would be reminded within "
                        + "\(options.clusterWindowMinutes) minutes of each other, at times Nudgy suggested "
                        + "rather than times your record named. "
                        + "This is about how notifications arrive on your phone, not about your care.",
                    citations: distinct.compactMap { drafts[$0].facts.first?.citation },
                    suggestedAction: "You can bundle these into one reminder, stagger them, or leave them as they are."
                )
                for index in distinct {
                    result[drafts[index].id, default: []].append(flag)
                }
                consumed.insert(start)
                start = end + 1
            } else {
                start += 1
            }
        }
        return result
    }

    // MARK: - Formatting helpers

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    static func clockText(minutes: Int) -> String {
        var components = DateComponents()
        components.year = 2000
        components.month = 1
        components.day = 1
        components.hour = minutes / 60
        components.minute = minutes % 60
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let date = calendar.date(from: components) else { return "" }
        let formatter = clockFormatter
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func clockText(_ components: DateComponents) -> String {
        guard let hour = components.hour, let minute = components.minute else { return "Time not set" }
        return clockText(minutes: hour * 60 + minute)
    }

    private func orderedUnique(_ values: [Int]) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for value in values where seen.insert(value).inserted { result.append(value) }
        return result
    }

    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }
}
