import Foundation

/// One connector's worth of decoded FHIR, tagged with who it came from.
///
/// The descriptor travels with the resources because a citation without a true source label is
/// worthless — "your record says" has to name *which* record.
struct ImportedSource: Hashable {
    let descriptor: HealthSourceDescriptor
    let resources: [FHIRResource]

    init(descriptor: HealthSourceDescriptor, resources: [FHIRResource]) {
        self.descriptor = descriptor
        self.resources = resources
    }
}

/// FHIR resources from one or more connectors → a `CareRecordSnapshot`.
///
/// Deliberate behaviours:
///
/// - **Only `status == "active"`.** A completed or cancelled order is not something to be
///   reminded about.
/// - **Deduplicates genuinely identical orders**, and only those. Two records for the same drug
///   from two different organizations are kept as two items even when they look similar, because
///   collapsing them would destroy the disagreement the proposal engine has to surface. Merging
///   is a clinical judgement; Nudgy does not make one.
/// - **Every field carries a citation with a real `fieldPath`** and the true source label,
///   preferring what the record itself names (`performer` → `requester` →
///   `informationSource` → `author`) over the connector's descriptor.
struct CareRecordNormalizer {
    private let dosageParser: DosageInstructionParser
    private let therapyParser: TherapyTaskParser

    init(
        dosageParser: DosageInstructionParser = DosageInstructionParser(),
        therapyParser: TherapyTaskParser = TherapyTaskParser()
    ) {
        self.dosageParser = dosageParser
        self.therapyParser = therapyParser
    }

    // MARK: - Entry points

    func snapshot(from imports: [ImportedSource], importedAt: Date = Date()) -> CareRecordSnapshot {
        var snapshot = CareRecordSnapshot()
        snapshot.importedAt = importedAt

        var medications: [MedicationItem] = []
        var therapyTasks: [TherapyTask] = []
        var allergies: [String] = []
        var patientName: String?

        for source in imports {
            let descriptor = source.descriptor
            for resource in source.resources {
                switch resource {
                case .patient(let patient):
                    if patientName == nil { patientName = patient.displayName }

                case .medicationRequest(let request):
                    if let item = medication(from: request, descriptor: descriptor) {
                        medications.append(item)
                    }

                case .medicationStatement(let statement):
                    if let item = medication(from: statement, descriptor: descriptor) {
                        medications.append(item)
                    }

                case .carePlan(let plan):
                    guard plan.status?.lowercased() == "active" else { continue }
                    therapyTasks.append(
                        contentsOf: therapyParser.tasks(
                            from: plan,
                            fallbackSourceLabel: descriptor.displayName,
                            dataOrigin: descriptor.dataOrigin
                        )
                    )

                case .allergyIntolerance(let allergy):
                    guard allergy.isActive,
                          let label = allergy.code?.bestDisplay?.nilIfEmpty else { continue }
                    if !allergies.contains(label) { allergies.append(label) }

                case .appointment, .condition, .unsupported:
                    continue
                }
            }
        }

        snapshot.patientDisplayName = patientName
        snapshot.medications = deduplicate(medications)
        snapshot.therapyTasks = deduplicate(therapyTasks)
        snapshot.allergies = allergies
        snapshot.sourceLabels = orderedUnique(
            snapshot.medications.map(\.sourceLabel) + snapshot.therapyTasks.map(\.sourceLabel)
        )
        return snapshot
    }

    /// Convenience for the single-source case.
    func snapshot(
        resources: [FHIRResource],
        from descriptor: HealthSourceDescriptor,
        importedAt: Date = Date()
    ) -> CareRecordSnapshot {
        snapshot(
            from: [ImportedSource(descriptor: descriptor, resources: resources)],
            importedAt: importedAt
        )
    }

    // MARK: - Medications

    private func medication(
        from request: FHIRMedicationRequest,
        descriptor: HealthSourceDescriptor
    ) -> MedicationItem? {
        guard request.status?.lowercased() == "active" else { return nil }
        guard let resourceID = request.id?.nilIfEmpty else { return nil }
        guard let name = request.medicationDisplay?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }

        // The record's own attribution wins over the connector's name.
        let sourceLabel = request.performer?.display?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? request.requester?.display?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? descriptor.displayName

        let context = CitationContext(
            sourceLabel: sourceLabel,
            resourceType: "MedicationRequest",
            resourceID: resourceID,
            recordedDate: request.authoredOn,
            dataOrigin: descriptor.dataOrigin
        )

        let namePath = (request.medicationCodeableConcept?.text?.isEmpty == false)
            ? "medicationCodeableConcept.text"
            : (request.medicationCodeableConcept != nil
               ? "medicationCodeableConcept.coding[0].display"
               : "medicationReference.display")

        let parsed = dosageParser.parse(
            request.dosageInstruction?.first,
            fieldPathPrefix: "dosageInstruction[0]",
            context: context
        )

        return MedicationItem(
            id: "MedicationRequest/\(resourceID)",
            displayName: name,
            nameCitation: context.citation(path: namePath, verbatim: name),
            instructionText: parsed.verbatimText,
            instructionCitation: parsed.instructionCitation,
            schedule: parsed.schedule,
            scheduleCitation: parsed.scheduleCitation,
            foodInstruction: parsed.foodInstruction,
            route: parsed.route,
            isAsNeeded: parsed.isAsNeeded,
            sourceLabel: sourceLabel,
            authoredOn: request.authoredOn,
            dataOrigin: descriptor.dataOrigin
        )
    }

    private func medication(
        from statement: FHIRMedicationStatement,
        descriptor: HealthSourceDescriptor
    ) -> MedicationItem? {
        guard statement.status?.lowercased() == "active" else { return nil }
        guard let resourceID = statement.id?.nilIfEmpty else { return nil }
        guard let name = statement.medicationDisplay?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }

        let sourceLabel = statement.informationSource?.display?
            .trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? descriptor.displayName

        let context = CitationContext(
            sourceLabel: sourceLabel,
            resourceType: "MedicationStatement",
            resourceID: resourceID,
            recordedDate: statement.dateAsserted,
            dataOrigin: descriptor.dataOrigin
        )

        let namePath = (statement.medicationCodeableConcept?.text?.isEmpty == false)
            ? "medicationCodeableConcept.text"
            : "medicationCodeableConcept.coding[0].display"

        let parsed = dosageParser.parse(
            statement.dosage?.first,
            fieldPathPrefix: "dosage[0]",
            context: context
        )

        return MedicationItem(
            id: "MedicationStatement/\(resourceID)",
            displayName: name,
            nameCitation: context.citation(path: namePath, verbatim: name),
            instructionText: parsed.verbatimText,
            instructionCitation: parsed.instructionCitation,
            schedule: parsed.schedule,
            scheduleCitation: parsed.scheduleCitation,
            foodInstruction: parsed.foodInstruction,
            route: parsed.route,
            isAsNeeded: parsed.isAsNeeded,
            sourceLabel: sourceLabel,
            authoredOn: statement.dateAsserted,
            dataOrigin: descriptor.dataOrigin
        )
    }

    // MARK: - Deduplication

    /// Collapses medications that are the *same order stated twice*: same drug, same source, same
    /// instruction, same cadence, same food instruction, same as-needed flag.
    ///
    /// Note what is deliberately part of the key: `sourceLabel`, `instructionText` and the food
    /// instruction. Change any of those and the two records are kept separately, because that is
    /// precisely the cross-source disagreement `ReminderProposalEngine` has to flag.
    private func deduplicate(_ medications: [MedicationItem]) -> [MedicationItem] {
        var seen: Set<String> = []
        var result: [MedicationItem] = []
        for item in medications {
            let scheduleKey: String
            if let schedule = item.schedule {
                scheduleKey = "\(schedule.frequency)/\(schedule.period)\(schedule.periodUnit.rawValue)"
                    + "|\(schedule.whenCodes.joined(separator: ","))"
            } else {
                scheduleKey = "none"
            }
            let key = [
                item.reconciliationKey,
                item.sourceLabel.lowercased(),
                item.instructionText?.lowercased() ?? "",
                scheduleKey,
                item.foodInstruction?.verbatim.lowercased() ?? "",
                item.isAsNeeded ? "prn" : "scheduled"
            ].joined(separator: "\u{1F}")
            if seen.insert(key).inserted { result.append(item) }
        }
        return result
    }

    /// Therapy tasks are already keyed by plan + activity name inside the parser; this collapses
    /// the same activity arriving from two imports of the same bundle.
    private func deduplicate(_ tasks: [TherapyTask]) -> [TherapyTask] {
        var seen: Set<String> = []
        var result: [TherapyTask] = []
        for task in tasks where seen.insert(task.id).inserted {
            result.append(task)
        }
        return result
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
