import Foundation

/// Minimal FHIR R4 decoding, scoped to the resources Nudgy actually reads.
///
/// This is intentionally not a general FHIR library. It decodes the elements the reminder engine
/// needs and preserves the raw text of anything it will later quote back to the user.

// MARK: - Shared elements

struct FHIRCoding: Decodable, Hashable {
    var system: String?
    var code: String?
    var display: String?
}

struct FHIRCodeableConcept: Decodable, Hashable {
    var coding: [FHIRCoding]?
    var text: String?

    /// Best human-readable label: explicit text wins, then the first coding display.
    var bestDisplay: String? {
        if let text, !text.isEmpty { return text }
        return coding?.compactMap(\.display).first
    }
}

struct FHIRReference: Decodable, Hashable {
    var reference: String?
    var display: String?
}

struct FHIRQuantity: Decodable, Hashable {
    var value: Double?
    var unit: String?

    var described: String? {
        guard let value else { return nil }
        let number = value == value.rounded() ? String(Int(value)) : String(value)
        guard let unit, !unit.isEmpty else { return number }
        return "\(number) \(unit)"
    }
}

struct FHIRPeriod: Decodable, Hashable {
    var start: Date?
    var end: Date?
}

struct FHIRTimingRepeat: Decodable, Hashable {
    var frequency: Int?
    var period: Double?
    var periodUnit: String?
    /// Event-anchored timing codes such as ACM (before breakfast) or HS (bedtime).
    var when: [String]?
}

struct FHIRTiming: Decodable, Hashable {
    var repeatElement: FHIRTimingRepeat?

    private enum CodingKeys: String, CodingKey {
        // `repeat` is a Swift keyword, so it is mapped explicitly.
        case repeatElement = "repeat"
    }
}

struct FHIRDoseAndRate: Decodable, Hashable {
    var doseQuantity: FHIRQuantity?
}

/// FHIR `Dosage`, shared by MedicationRequest.dosageInstruction and MedicationStatement.dosage.
struct FHIRDosage: Decodable, Hashable {
    var sequence: Int?
    var text: String?
    var additionalInstruction: [FHIRCodeableConcept]?
    var timing: FHIRTiming?
    var asNeededBoolean: Bool?
    var route: FHIRCodeableConcept?
    var doseAndRate: [FHIRDoseAndRate]?
}

// MARK: - Resources

struct FHIRHumanName: Decodable, Hashable {
    var use: String?
    var family: String?
    var given: [String]?

    var formatted: String? {
        let parts = ((given ?? []) + [family].compactMap { $0 })
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        // Synthea appends digits to names ("Terry864"). Strip them for display.
        let cleaned = parts.map { $0.replacingOccurrences(of: "[0-9]+", with: "", options: .regularExpression) }
        return cleaned.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

struct FHIRPatient: Decodable, Hashable {
    var id: String?
    var name: [FHIRHumanName]?
    var gender: String?
    var birthDate: Date?
    var managingOrganization: FHIRReference?

    var displayName: String? {
        name?.first(where: { $0.use == "official" })?.formatted ?? name?.first?.formatted
    }
}

struct FHIRMedicationRequest: Decodable, Hashable {
    var id: String?
    var status: String?
    var intent: String?
    var medicationCodeableConcept: FHIRCodeableConcept?
    var medicationReference: FHIRReference?
    var authoredOn: Date?
    var requester: FHIRReference?
    var performer: FHIRReference?
    var dosageInstruction: [FHIRDosage]?

    var medicationDisplay: String? {
        medicationCodeableConcept?.bestDisplay ?? medicationReference?.display
    }
}

struct FHIRMedicationStatement: Decodable, Hashable {
    var id: String?
    var status: String?
    var medicationCodeableConcept: FHIRCodeableConcept?
    var dateAsserted: Date?
    var informationSource: FHIRReference?
    var dosage: [FHIRDosage]?

    var medicationDisplay: String? { medicationCodeableConcept?.bestDisplay }
}

struct FHIRCarePlanActivityDetail: Decodable, Hashable {
    var status: String?
    var code: FHIRCodeableConcept?
    var description: String?
    var scheduledTiming: FHIRTiming?
    var quantity: FHIRQuantity?
}

struct FHIRCarePlanActivity: Decodable, Hashable {
    var detail: FHIRCarePlanActivityDetail?
}

struct FHIRCarePlan: Decodable, Hashable {
    var id: String?
    var status: String?
    var intent: String?
    var title: String?
    var description: String?
    var category: [FHIRCodeableConcept]?
    var period: FHIRPeriod?
    var author: FHIRReference?
    var activity: [FHIRCarePlanActivity]?

    /// Synthea encodes the plan's subject in a second category entry; the first is a US Core code.
    var bestTitle: String? {
        if let title, !title.isEmpty { return title }
        return category?.compactMap(\.bestDisplay).last
    }
}

struct FHIRAllergyIntolerance: Decodable, Hashable {
    var id: String?
    var clinicalStatus: FHIRCodeableConcept?
    var code: FHIRCodeableConcept?
    var criticality: String?
    /// "food", "medication", "environment", "biologic". Decides whether this belongs on a meal card.
    var category: [String]?

    var isActive: Bool {
        clinicalStatus?.coding?.contains { $0.code == "active" } ?? false
    }
}

struct FHIRAppointment: Decodable, Hashable {
    var id: String?
    var status: String?
    var description: String?
    var start: Date?
    var comment: String?
}

/// FHIR `NutritionOrder` — the resource that carries a prescribed diet, including the one field
/// nothing else has: `excludeFoodModifier`, i.e. foods the order says to avoid.
struct FHIRNutritionOrder: Decodable, Hashable {
    struct OralDiet: Decodable, Hashable {
        var type: [FHIRCodeableConcept]?
        var schedule: [FHIRTiming]?
        var instruction: String?
    }

    var id: String?
    var status: String?
    var intent: String?
    var dateTime: Date?
    var orderer: FHIRReference?
    var oralDiet: OralDiet?
    /// Foods the order excludes. Preserved verbatim — never normalised into a category.
    var excludeFoodModifier: [FHIRCodeableConcept]?
    var foodPreferenceModifier: [FHIRCodeableConcept]?
    var note: [FHIRAnnotation]?

    var isActive: Bool { status == "active" || status == nil }
}

struct FHIRAnnotation: Decodable, Hashable {
    var text: String?
}

struct FHIRCondition: Decodable, Hashable {
    var id: String?
    var clinicalStatus: FHIRCodeableConcept?
    var code: FHIRCodeableConcept?
}

// MARK: - Resource envelope

enum FHIRResource: Hashable {
    case patient(FHIRPatient)
    case medicationRequest(FHIRMedicationRequest)
    case medicationStatement(FHIRMedicationStatement)
    case carePlan(FHIRCarePlan)
    case allergyIntolerance(FHIRAllergyIntolerance)
    case appointment(FHIRAppointment)
    case condition(FHIRCondition)
    case nutritionOrder(FHIRNutritionOrder)
    /// A resource type Nudgy does not read. Kept so import counts stay honest.
    case unsupported(type: String)

    var resourceTypeName: String {
        switch self {
        case .patient: return "Patient"
        case .medicationRequest: return "MedicationRequest"
        case .medicationStatement: return "MedicationStatement"
        case .carePlan: return "CarePlan"
        case .allergyIntolerance: return "AllergyIntolerance"
        case .appointment: return "Appointment"
        case .condition: return "Condition"
        case .nutritionOrder: return "NutritionOrder"
        case .unsupported(let type): return type
        }
    }
}

extension FHIRResource: Decodable {
    private enum DiscriminatorKeys: String, CodingKey {
        case resourceType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DiscriminatorKeys.self)
        let type = try container.decode(String.self, forKey: .resourceType)
        let single = decoder

        switch type {
        case "Patient":
            self = .patient(try FHIRPatient(from: single))
        case "MedicationRequest":
            self = .medicationRequest(try FHIRMedicationRequest(from: single))
        case "MedicationStatement":
            self = .medicationStatement(try FHIRMedicationStatement(from: single))
        case "CarePlan":
            self = .carePlan(try FHIRCarePlan(from: single))
        case "AllergyIntolerance":
            self = .allergyIntolerance(try FHIRAllergyIntolerance(from: single))
        case "Appointment":
            self = .appointment(try FHIRAppointment(from: single))
        case "Condition":
            self = .condition(try FHIRCondition(from: single))
        case "NutritionOrder":
            self = .nutritionOrder(try FHIRNutritionOrder(from: single))
        default:
            self = .unsupported(type: type)
        }
    }
}

struct FHIRBundleEntry: Decodable {
    var fullUrl: String?
    var resource: FHIRResource?
}

struct FHIRBundle: Decodable {
    var id: String?
    var type: String?
    var meta: FHIRMeta?
    var entry: [FHIRBundleEntry]?

    struct FHIRMeta: Decodable {
        var tag: [FHIRCoding]?
    }

    var resources: [FHIRResource] { (entry ?? []).compactMap(\.resource) }

    /// Honors the `data-origin` tag Nudgy stamps on authored sample bundles.
    var declaredOrigin: DataOrigin? {
        guard let tag = meta?.tag?.first(where: {
            $0.system == "https://nudgy.app/fhir/CodeSystem/data-origin"
        }) else { return nil }
        return tag.code == "authored-demo" ? .authoredDemo : nil
    }
}

// MARK: - Decoding

enum FHIRDecoder {
    /// FHIR mixes full instants, dates, and offsets. A single strategy handles all three.
    static func make() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parse(raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized FHIR date/time: \(raw)"
            )
        }
        return decoder
    }

    private static let instantFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let yearMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    static func parse(_ raw: String) -> Date? {
        if let date = fractionalFormatter.date(from: raw) { return date }
        if let date = instantFormatter.date(from: raw) { return date }
        if let date = dateOnlyFormatter.date(from: raw) { return date }
        if let date = yearMonthFormatter.date(from: raw) { return date }
        return nil
    }
}
