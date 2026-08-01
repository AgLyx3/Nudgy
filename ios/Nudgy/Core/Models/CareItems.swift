import Foundation

/// How often something is taken or performed, as stated by the record.
///
/// Note what this deliberately does *not* contain: a time of day. FHIR rarely encodes one, and
/// inventing one would be clinical advice. Time of day is decided later, by the user, and is
/// labelled as a convenience suggestion when Nudgy proposes it.
struct DosingSchedule: Codable, Hashable {
    enum PeriodUnit: String, Codable, Hashable {
        case second = "s"
        case minute = "min"
        case hour = "h"
        case day = "d"
        case week = "wk"
        case month = "mo"
        case year = "a"

        var singularNoun: String {
            switch self {
            case .second: return "second"
            case .minute: return "minute"
            case .hour: return "hour"
            case .day: return "day"
            case .week: return "week"
            case .month: return "month"
            case .year: return "year"
            }
        }
    }

    /// Number of administrations per `period`.
    let frequency: Int
    let period: Double
    let periodUnit: PeriodUnit
    /// FHIR `Timing.repeat.when` codes (ACM = before breakfast, HS = bedtime, and so on).
    /// These are the only time-of-day hints that are genuinely clinical, because the chart said them.
    let whenCodes: [String]

    init(frequency: Int, period: Double, periodUnit: PeriodUnit, whenCodes: [String] = []) {
        self.frequency = frequency
        self.period = period
        self.periodUnit = periodUnit
        self.whenCodes = whenCodes
    }

    /// How many times a day, when that is well defined. Nil when the cadence is not daily
    /// (e.g. weekly) or cannot be expressed as a whole number of daily events.
    var timesPerDay: Int? {
        guard period > 0 else { return nil }
        switch periodUnit {
        case .day:
            guard period == 1 else { return nil }
            return frequency
        case .hour:
            let perDay = (24.0 / period) * Double(frequency)
            guard perDay >= 1, perDay == perDay.rounded() else { return nil }
            return Int(perDay)
        default:
            return nil
        }
    }

    /// Plain restatement of the cadence. Describes only what the record said.
    var plainLanguage: String {
        if let perDay = timesPerDay {
            switch perDay {
            case 1: return "once daily"
            case 2: return "twice daily"
            case 3: return "three times daily"
            case 4: return "four times daily"
            default: return "\(perDay) times daily"
            }
        }
        let unit = periodUnit.singularNoun
        let periodText = period == 1 ? "every \(unit)" : "every \(formatted(period)) \(unit)s"
        return frequency == 1 ? periodText : "\(frequency) times \(periodText)"
    }

    private func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// A food or administration instruction, preserved exactly as written.
struct FoodInstruction: Codable, Hashable {
    let verbatim: String
    let citation: SourceCitation
}

/// A medication as Nudgy understands it after normalization. Every clinical field either has a
/// citation or is explicitly absent — there is no "reasonable default" anywhere in this type.
struct MedicationItem: Codable, Hashable, Identifiable {
    let id: String
    /// e.g. "Metformin hydrochloride 500 MG Oral Tablet"
    let displayName: String
    let nameCitation: SourceCitation
    /// Verbatim `dosageInstruction.text` when the record has one.
    let instructionText: String?
    let instructionCitation: SourceCitation?
    let schedule: DosingSchedule?
    let scheduleCitation: SourceCitation?
    let foodInstruction: FoodInstruction?
    let route: String?
    let isAsNeeded: Bool
    let sourceLabel: String
    let authoredOn: Date?
    let dataOrigin: DataOrigin

    /// Normalized key used to detect the same drug arriving from two different portals.
    var reconciliationKey: String {
        displayName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A short name for conversational use: "Metformin 500 MG" rather than the full RxNorm string.
    var conversationalName: String {
        let trimmed = displayName
            .replacingOccurrences(of: " Oral Tablet", with: "")
            .replacingOccurrences(of: " Oral Capsule", with: "")
            .trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? displayName : trimmed
    }
}

/// A physical therapy or home exercise task.
struct TherapyTask: Codable, Hashable, Identifiable {
    let id: String
    let exerciseName: String
    /// Verbatim instruction from the care plan activity.
    let instructionText: String?
    let schedule: DosingSchedule?
    /// e.g. "10 repetitions" — only when the record states it.
    let quantityDescription: String?
    /// Equipment Nudgy found *named in the instruction text*. Never inferred from the exercise name.
    let equipmentMentioned: String?
    let planTitle: String?
    let sourceLabel: String
    let citation: SourceCitation
    let dataOrigin: DataOrigin
    /// Fields the design doc asks PT reminders to carry that this record does not supply.
    let detailGaps: [ReviewReason]
}

/// Everything Nudgy has normalized out of the connected sources.
struct CareRecordSnapshot: Codable, Hashable {
    var patientDisplayName: String?
    var medications: [MedicationItem] = []
    var therapyTasks: [TherapyTask] = []
    var allergies: [String] = []
    var importedAt: Date = .init()
    var sourceLabels: [String] = []

    var isEmpty: Bool { medications.isEmpty && therapyTasks.isEmpty }
}
