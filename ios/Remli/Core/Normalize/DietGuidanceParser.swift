import Foundation

/// Pulls what the record says about food out of care plans, nutrition orders, and food allergies.
///
/// ## The boundary this file exists to hold
///
/// Remli restates. It does not compose. A `NutritionOrder` saying "Diabetic diet" becomes a card
/// that says "your plan lists a diabetic diet" — never a menu, a nutrient target, or a suggestion
/// about what to eat at a barbecue. Every field here carries a citation for the same reason every
/// medication field does: the moment a food claim appears without one, it is Remli's claim, and
/// Remli has no basis for claims about food.
///
/// Foods to avoid are read only from `excludeFoodModifier` and recorded allergies. Nothing is
/// inferred from a diagnosis — "diabetic" does not become "avoid sugar", because that is dietetics
/// and it is not what the order said.
struct DietGuidanceParser {

    /// SNOMED codes Synthea and Epic use for diet entries on a care plan.
    static let dietSNOMEDCodes: Set<String> = [
        "160670007",  // Diabetic diet
        "435551000124108", // Dietary Approaches to Stop Hypertension diet
        "226234005",  // Healthy diet
        "182922004",  // Dietary regime
        "39179001",   // Low sodium diet
        "437231000124109" // Low fat diet
    ]

    static let dietTextFragments = [
        "diet", "dietary", "nutrition", "food intake", "meal plan"
    ]

    static func indicatesDiet(_ text: String?) -> Bool {
        guard let lowered = text?.lowercased() else { return false }
        return dietTextFragments.contains { lowered.contains($0) }
    }

    // MARK: - Care plans

    /// Diet activities on a care plan.
    ///
    /// These were previously discarded: the therapy parser skips them because they are not
    /// exercise, and nothing else looked at them. Terry Glover's Synthea record alone carries a
    /// "Diabetic diet" and a "Dietary Approaches to Stop Hypertension diet" that never reached the
    /// user.
    func guidance(
        fromCarePlan plan: FHIRCarePlan,
        fallbackSourceLabel: String,
        dataOrigin: DataOrigin
    ) -> [DietaryGuidance] {
        guard plan.status == "active" else { return [] }
        let sourceLabel = (plan.author?.display?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? fallbackSourceLabel).strippingGeneratedNameDigits
        let planTitle = plan.bestTitle
        let resourceID = plan.id ?? UUID().uuidString

        var seen = Set<String>()
        var results: [DietaryGuidance] = []

        for (index, activity) in (plan.activity ?? []).enumerated() {
            guard let detail = activity.detail else { continue }
            let codes = Set((detail.code?.coding ?? []).compactMap(\.code))
            let label = detail.code?.bestDisplay

            let isDiet = !codes.isDisjoint(with: Self.dietSNOMEDCodes)
                || Self.indicatesDiet(label)
            guard isDiet, let displayText = label else { continue }

            // Synthea repeats identical activities; one card per distinct diet is enough.
            let key = displayText.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            results.append(
                DietaryGuidance(
                    id: "CarePlan/\(resourceID)#diet-\(key.slugified)",
                    kind: .prescribedDiet,
                    displayText: displayText,
                    citation: SourceCitation(
                        sourceLabel: sourceLabel,
                        resourceType: "CarePlan",
                        resourceID: resourceID,
                        fieldPath: "activity[\(index)].detail.code.text",
                        verbatimText: displayText,
                        recordedDate: plan.period?.start,
                        dataOrigin: dataOrigin
                    ),
                    instructionText: detail.description,
                    // A named diet applies to eating generally, not to one sitting.
                    mealAnchors: MealAnchor.allCases,
                    planTitle: planTitle,
                    sourceLabel: sourceLabel,
                    dataOrigin: dataOrigin
                )
            )
        }
        return results
    }

    // MARK: - Nutrition orders

    func guidance(
        fromNutritionOrder order: FHIRNutritionOrder,
        fallbackSourceLabel: String,
        dataOrigin: DataOrigin
    ) -> [DietaryGuidance] {
        guard order.isActive else { return [] }
        let sourceLabel = (order.orderer?.display?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? fallbackSourceLabel).strippingGeneratedNameDigits
        let resourceID = order.id ?? UUID().uuidString
        let anchors = Self.anchors(in: order.oralDiet?.schedule ?? [])
        var results: [DietaryGuidance] = []

        for (index, type) in (order.oralDiet?.type ?? []).enumerated() {
            guard let displayText = type.bestDisplay else { continue }
            results.append(
                DietaryGuidance(
                    id: "NutritionOrder/\(resourceID)#diet-\(index)",
                    kind: .prescribedDiet,
                    displayText: displayText,
                    citation: SourceCitation(
                        sourceLabel: sourceLabel,
                        resourceType: "NutritionOrder",
                        resourceID: resourceID,
                        fieldPath: "oralDiet.type[\(index)].text",
                        verbatimText: displayText,
                        recordedDate: order.dateTime,
                        dataOrigin: dataOrigin
                    ),
                    instructionText: order.oralDiet?.instruction,
                    mealAnchors: anchors.isEmpty ? MealAnchor.allCases : anchors,
                    planTitle: nil,
                    sourceLabel: sourceLabel,
                    dataOrigin: dataOrigin
                )
            )
        }

        // The one field that literally means "foods to avoid". Kept verbatim, never generalised.
        for (index, exclude) in (order.excludeFoodModifier ?? []).enumerated() {
            guard let displayText = exclude.bestDisplay else { continue }
            results.append(
                DietaryGuidance(
                    id: "NutritionOrder/\(resourceID)#avoid-\(index)",
                    kind: .avoid,
                    displayText: displayText,
                    citation: SourceCitation(
                        sourceLabel: sourceLabel,
                        resourceType: "NutritionOrder",
                        resourceID: resourceID,
                        fieldPath: "excludeFoodModifier[\(index)].text",
                        verbatimText: displayText,
                        recordedDate: order.dateTime,
                        dataOrigin: dataOrigin
                    ),
                    instructionText: nil,
                    mealAnchors: anchors.isEmpty ? MealAnchor.allCases : anchors,
                    planTitle: nil,
                    sourceLabel: sourceLabel,
                    dataOrigin: dataOrigin
                )
            )
        }
        return results
    }

    // MARK: - Food allergies

    /// Only `category: food` allergies. A penicillin allergy is real and important, but it is not
    /// something to surface at dinner, and putting it on a meal card would train people to skim
    /// the card.
    func guidance(
        fromAllergy allergy: FHIRAllergyIntolerance,
        categories: [String],
        fallbackSourceLabel: String,
        dataOrigin: DataOrigin
    ) -> DietaryGuidance? {
        guard allergy.isActive,
              categories.contains("food"),
              let displayText = allergy.code?.bestDisplay else { return nil }
        let resourceID = allergy.id ?? UUID().uuidString

        return DietaryGuidance(
            id: "AllergyIntolerance/\(resourceID)",
            kind: .allergy,
            displayText: displayText,
            citation: SourceCitation(
                sourceLabel: fallbackSourceLabel,
                resourceType: "AllergyIntolerance",
                resourceID: resourceID,
                fieldPath: "code.text",
                verbatimText: displayText,
                recordedDate: nil,
                dataOrigin: dataOrigin
            ),
            instructionText: allergy.criticality.map { "Recorded criticality: \($0)" },
            mealAnchors: MealAnchor.allCases,
            planTitle: nil,
            sourceLabel: fallbackSourceLabel,
            dataOrigin: dataOrigin
        )
    }

    // MARK: - Helpers

    /// Meal anchors the order itself names, via `Timing.repeat.when`.
    static func anchors(in timings: [FHIRTiming]) -> [MealAnchor] {
        var found: [MealAnchor] = []
        for timing in timings {
            for code in timing.repeatElement?.when ?? [] {
                switch code.uppercased() {
                case "ACM", "PCM", "CM": found.append(.breakfast)
                case "ACD", "PCD", "CD": found.append(.lunch)
                case "ACV", "PCV", "CV": found.append(.dinner)
                default: break
                }
            }
        }
        return Array(Set(found)).sorted { lhs, rhs in
            MealAnchor.allCases.firstIndex(of: lhs)! < MealAnchor.allCases.firstIndex(of: rhs)!
        }
    }
}

extension String {
    var slugified: String {
        lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
