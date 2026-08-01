import Foundation

/// Turns a FHIR `CarePlan` into physical-therapy / home-exercise tasks.
///
/// Two rules dominate this file:
///
/// 1. **Only genuinely therapeutic activities become tasks.** A Synthea diabetes care plan
///    contains "Diabetic diet" and "Counseling about alcohol consumption" alongside
///    "Exercise therapy". Proposing an exercise reminder for a dietary counselling code would be
///    Nudgy inventing a care action.
/// 2. **Equipment is only ever reported when the instruction text literally names it.** The
///    exercise called "Wall slides" does not imply a wall, and "Resistance band external
///    rotation" does not imply a band — but its description saying "Using the green resistance
///    band" does. Inferring equipment from an exercise name is exactly the class of guess the
///    design doc forbids.
///
/// What the record does not say is recorded honestly in `TherapyTask.detailGaps`, which the
/// proposal engine turns into "please confirm this with your care team".
struct TherapyTaskParser {

    init() {}

    // MARK: - Therapy recognition

    /// SNOMED codes that mean "this is physical therapy or prescribed exercise".
    static let therapySNOMEDCodes: Set<String> = [
        "91251008",   // Physical therapy procedure
        "386463000",  // Prescribed activity/exercise education
        "229065009",  // Exercise therapy
        "226060000",  // Physical activity target
        "410158009"   // Physiotherapy education
    ]

    /// Text fragments that mean the same thing. Deliberately specific: bare "therapy" matches
    /// cognitive behavioural therapy and speech therapy too, so it is not on this list.
    static let therapyTextFragments: [String] = [
        "physical therapy",
        "physiotherapy",
        "exercise therapy",
        "home exercise",
        "exercise program",
        "exercise programme",
        "prescribed activity",
        "activity/exercise",
        "therapeutic exercise",
        "range of motion exercise",
        "strengthening exercise",
        "rehabilitation exercise"
    ]

    /// True when a coded concept names physical therapy or prescribed exercise.
    static func indicatesTherapy(_ concept: FHIRCodeableConcept?) -> Bool {
        guard let concept else { return false }
        if let coding = concept.coding {
            for code in coding {
                if let value = code.code, therapySNOMEDCodes.contains(value) { return true }
                if indicatesTherapy(text: code.display) { return true }
            }
        }
        return indicatesTherapy(text: concept.text)
    }

    static func indicatesTherapy(text: String?) -> Bool {
        guard let text = text?.lowercased(), !text.isEmpty else { return false }
        return therapyTextFragments.contains { text.contains($0) }
    }

    // MARK: - Parsing

    /// - Parameters:
    ///   - plan: an already status-filtered `CarePlan`.
    ///   - fallbackSourceLabel: the connector's descriptor name, used when the plan names no author.
    ///   - dataOrigin: the origin that applies to this import.
    func tasks(
        from plan: FHIRCarePlan,
        fallbackSourceLabel: String,
        dataOrigin: DataOrigin
    ) -> [TherapyTask] {
        let planID = plan.id ?? "unknown"
        let sourceLabel = plan.author?.display?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? fallbackSourceLabel
        let recordedDate = plan.period?.start
        let context = CitationContext(
            sourceLabel: sourceLabel,
            resourceType: "CarePlan",
            resourceID: planID,
            recordedDate: recordedDate,
            dataOrigin: dataOrigin
        )

        // A plan whose own title/category says "physical therapy" is a therapy programme, so all
        // of its activities are therapy tasks — that is how the authored shoulder plan carries
        // "Pendulum swings", a name no keyword list would ever match.
        let planIsTherapyProgramme =
            Self.indicatesTherapy(text: plan.title)
            || (plan.category ?? []).contains { Self.indicatesTherapy($0) }

        var tasks: [TherapyTask] = []
        var seenIDs: Set<String> = []

        for (index, activity) in (plan.activity ?? []).enumerated() {
            guard let detail = activity.detail else { continue }
            // Skip activities the record has already closed out.
            if let status = detail.status?.lowercased(),
               ["cancelled", "stopped", "completed", "entered-in-error"].contains(status) {
                continue
            }

            let qualifies = planIsTherapyProgramme || Self.indicatesTherapy(detail.code)
            guard qualifies else { continue }

            guard let name = detail.code?.bestDisplay?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { continue }

            // Stable across imports and independent of activity ordering, which Synthea does not
            // guarantee. Also collapses the repeated identical activities Synthea emits.
            let taskID = "CarePlan/\(planID)#\(Self.slug(name))"
            guard !seenIDs.contains(taskID) else { continue }
            seenIDs.insert(taskID)

            let description = detail.description?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            let pathPrefix = "activity[\(index)].detail"
            let citation: SourceCitation
            if let description {
                citation = context.citation(path: "\(pathPrefix).description", verbatim: description)
            } else {
                citation = context.citation(path: "\(pathPrefix).code.text", verbatim: name)
            }

            // `TherapyTask` has one citation slot, so the activity citation above carries the
            // provenance for every field read out of this activity, including the cadence.
            var schedule: DosingSchedule?
            if let repeatElement = detail.scheduledTiming?.repeatElement {
                schedule = DosageInstructionParser().parseSchedule(
                    repeatElement,
                    fieldPathPrefix: "\(pathPrefix).scheduledTiming.repeat",
                    context: context
                ).schedule
            }

            let quantityDescription = detail.quantity?.described
            let equipment = description.flatMap { Self.equipmentMentioned(in: $0) }

            var gaps: [ReviewReason] = []
            if !Self.describesHowToPerform(text: description, quantity: detail.quantity) {
                gaps.append(.therapyDetailIncomplete)
            }
            if equipment == nil {
                gaps.append(.equipmentUnclear)
            }
            if schedule == nil {
                gaps.append(.frequencyNotSpecified)
            }

            tasks.append(
                TherapyTask(
                    id: taskID,
                    exerciseName: name,
                    instructionText: description,
                    schedule: schedule,
                    quantityDescription: quantityDescription,
                    equipmentMentioned: equipment,
                    planTitle: plan.bestTitle,
                    sourceLabel: sourceLabel,
                    citation: citation,
                    dataOrigin: dataOrigin,
                    detailGaps: gaps
                )
            )
        }

        return tasks
    }

    // MARK: - Detail completeness

    /// Whether the record actually describes *how to perform* the exercise, rather than only
    /// naming it.
    ///
    /// A stated quantity counts. So does a repetition/hold/duration phrase in the text. "Perform
    /// daily as instructed in clinic." counts as neither, which is why Wall slides is reported as
    /// detail-incomplete even though it has a description.
    static func describesHowToPerform(text: String?, quantity: FHIRQuantity?) -> Bool {
        if quantity?.value != nil { return true }
        guard let text, !text.isEmpty else { return false }
        return repetitionOrDurationPhrase(in: text) != nil
    }

    private static let repetitionRegex = try? NSRegularExpression(
        pattern: #"\b\d+\s*(?:-\s*\d+\s*)?(?:x\b|reps?\b|repetitions?\b|sets?\b|circles?\b|times?\b|seconds?\b|secs?\b|minutes?\b|mins?\b|holds?\b)"#,
        options: [.caseInsensitive]
    )

    /// The verbatim repetition/duration phrase in the text, when there is one.
    static func repetitionOrDurationPhrase(in text: String) -> String? {
        guard let regex = repetitionRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }

    // MARK: - Equipment

    /// Equipment nouns. Ordered longest-first so "resistance band" wins over "band".
    ///
    /// Matched with word boundaries against the **instruction text only**. The exercise name is
    /// never searched.
    static let equipmentNouns: [String] = [
        "resistance band",
        "resistance tubing",
        "elastic band",
        "exercise band",
        "theraband",
        "thera-band",
        "stability ball",
        "exercise ball",
        "medicine ball",
        "foam roller",
        "exercise mat",
        "yoga mat",
        "yoga block",
        "ankle weight",
        "ankle weights",
        "wrist weight",
        "wrist weights",
        "hand weight",
        "hand weights",
        "cuff weight",
        "cuff weights",
        "dumbbell",
        "dumbbells",
        "kettlebell",
        "kettlebells",
        "barbell",
        "stationary bike",
        "exercise bike",
        "treadmill",
        "pulley",
        "crutch",
        "crutches",
        "walker",
        "cane",
        "doorway",
        "stairs",
        "bench",
        "towel",
        "strap",
        "chair",
        "pole",
        "band",
        "ball",
        "mat",
        "wall"
    ]

    private static let equipmentRegex: NSRegularExpression? = {
        let alternation = equipmentNouns
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "\\b(?:\(alternation))\\b",
            options: [.caseInsensitive]
        )
    }()

    /// The verbatim equipment phrase named in `text`, or nil.
    ///
    /// Nil does **not** mean "no equipment needed". It means the record did not say, which is
    /// reported as `.equipmentUnclear` rather than quietly assumed.
    static func equipmentMentioned(in text: String) -> String? {
        guard let regex = equipmentRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange])
    }

    // MARK: - Body position

    static let bodyPositionFragments: [String] = [
        "side-lying",
        "side lying",
        "lying down",
        "on your back",
        "on your stomach",
        "on your side",
        "bend forward",
        "bent forward",
        "standing",
        "kneeling",
        "seated",
        "supine",
        "prone",
        "upright",
        "kneel",
        "stand",
        "lying",
        "sit ",
        "lie "
    ]

    /// The verbatim sentence describing the body position, when the record states one.
    ///
    /// The design doc asks PT reminders to carry body position "if explicitly stated". `TherapyTask`
    /// has no field for it, so the engine quotes the sentence instead — still the record's own
    /// words, still under the instruction's citation.
    static func bodyPositionSentence(in text: String) -> String? {
        for sentence in sentences(in: text) {
            let lowered = sentence.lowercased()
            if bodyPositionFragments.contains(where: { lowered.contains($0) }) {
                return sentence
            }
        }
        return nil
    }

    static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    // MARK: - Helpers

    static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        while out.hasPrefix("-") { out.removeFirst() }
        return out.isEmpty ? "activity" : out
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
