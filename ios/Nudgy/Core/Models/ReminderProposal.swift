import Foundation

/// A single stated fact, shown to the user with its citation attached.
struct SourceFact: Codable, Hashable, Identifiable {
    let id: String
    /// e.g. "Instruction", "How often", "With food"
    let label: String
    let verbatim: String
    let citation: SourceCitation

    init(label: String, verbatim: String, citation: SourceCitation) {
        self.id = "\(citation.id)|\(label)"
        self.label = label
        self.verbatim = verbatim
        self.citation = citation
    }
}

/// One proposed notification time within a day.
struct ProposedSlot: Codable, Hashable, Identifiable {
    var id: String
    /// Nil means "the record does not say when". The UI must not silently pick one.
    var timeOfDay: DateComponents?
    var provenance: Provenance
    /// e.g. "Morning", "Evening", "Dose 1 of 2"
    var label: String

    init(id: String = UUID().uuidString, timeOfDay: DateComponents?, provenance: Provenance, label: String) {
        self.id = id
        self.timeOfDay = timeOfDay
        self.provenance = provenance
        self.label = label
    }

    var formattedTime: String {
        guard let timeOfDay,
              let hour = timeOfDay.hour,
              let minute = timeOfDay.minute else { return "Time not set" }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let calendar = Calendar.current
        guard let date = calendar.date(from: DateComponents(
            year: 2000, month: 1, day: 1, hour: hour, minute: minute
        )) else { return "Time not set" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

enum FlagSeverity: String, Codable, Hashable {
    /// Worth mentioning; not a safety matter.
    case info
    /// The design doc's "possible concern" — sources disagree, or a detail is missing that matters.
    case possibleConcern
}

/// Something Nudgy noticed but will not resolve on its own.
struct ProposalFlag: Codable, Hashable, Identifiable {
    let id: String
    let severity: FlagSeverity
    let title: String
    let detail: String
    let citations: [SourceCitation]
    /// What the user can do. Never a clinical instruction — usually "ask your care team".
    let suggestedAction: String?

    init(
        severity: FlagSeverity,
        title: String,
        detail: String,
        citations: [SourceCitation] = [],
        suggestedAction: String? = nil
    ) {
        self.id = "\(severity.rawValue)|\(title)|\(citations.map(\.id).joined(separator: ","))"
        self.severity = severity
        self.title = title
        self.detail = detail
        self.citations = citations
        self.suggestedAction = suggestedAction
    }
}

enum ReminderKind: String, Codable, Hashable {
    case medication
    case therapy

    var noun: String {
        switch self {
        case .medication: return "medication"
        case .therapy: return "exercise"
        }
    }
}

/// The unit of review. Produced entirely by the deterministic engine; the language model only
/// ever phrases one of these, never authors one.
struct ReminderProposal: Codable, Hashable, Identifiable {
    let id: String
    let kind: ReminderKind
    let title: String
    let subtitle: String?
    /// Verbatim facts with citations. Rendered as the "why am I seeing this" disclosure.
    let sourceFacts: [SourceFact]
    var slots: [ProposedSlot]
    let flags: [ProposalFlag]
    let primaryProvenance: Provenance
    let sourceLabel: String
    let dataOrigin: DataOrigin
    /// Set when the engine declines to propose a schedule at all (e.g. as-needed medication).
    let schedulingDeclinedReason: ReviewReason?

    /// True when at least one slot has no time and the user must supply it.
    var needsTimeOfDay: Bool { slots.contains { $0.timeOfDay == nil } }

    var hasPossibleConcern: Bool { flags.contains { $0.severity == .possibleConcern } }

    /// v1 requires individual approval for every reminder, without exception.
    var requiresIndividualApproval: Bool { true }
}

/// A proposal the user approved. This is the only thing that can schedule a notification.
struct ApprovedReminder: Codable, Hashable, Identifiable {
    let id: String
    let proposalID: String
    let kind: ReminderKind
    let title: String
    let body: String
    /// Concrete times. Every one has been seen and accepted by the user.
    var times: [DateComponents]
    let sourceFacts: [SourceFact]
    let sourceLabel: String
    let dataOrigin: DataOrigin
    var approvedAt: Date
    var isActive: Bool

    /// Notification request identifiers derived from this reminder.
    func notificationIdentifiers() -> [String] {
        times.indices.map { "nudgy.reminder.\(id).\($0)" }
    }
}

/// Recorded when the user skips a proposal, so Nudgy does not re-propose it every import.
struct SkippedProposal: Codable, Hashable, Identifiable {
    let id: String
    let proposalID: String
    let skippedAt: Date
}
