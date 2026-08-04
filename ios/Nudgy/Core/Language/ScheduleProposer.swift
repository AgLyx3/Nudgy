import Foundation

/// Asks Gemma to choose when a reminder should fire, then checks its answer.
///
/// ## Why this does not go through SafetyGuard
///
/// SafetyGuard vets *prose shown to a person* — it is a reader, and it reasons about attribution.
/// This path produces *structured data*, and structured data is better checked by schema: the
/// right number of times, inside waking hours, far enough apart, parseable at all. Running clock
/// times through a prose filter would be using the wrong tool, and inventing prose for the model
/// to emit just so it could be parsed back would add a failure mode rather than remove one.
///
/// So the division is: anything the user reads goes through SafetyGuard; anything the app acts on
/// goes through `validate`. Both are strict, in the way that suits what they are guarding.
///
/// ## Why a fallback always exists
///
/// Every reminder must arrive with a time — a card that cannot fire is not a reminder. So the
/// deterministic spacing from `ScheduleResolver` is not an error path, it is the floor. Gemma
/// improves on it when it is available and sensible; when it is missing, slow, or returns
/// something odd, nothing about the product stops working.
struct ScheduleProposer {

    /// Everything the model is told. Deliberately small: this is a scheduling question, and the
    /// model is given no diagnosis, no condition, and no reason for the medication.
    struct Request {
        /// e.g. "Metformin hydrochloride 500 MG"
        let itemName: String
        /// How many times a day the record says. Never inferred here.
        let timesPerDay: Int
        /// Verbatim instruction, when the record has one — it may name a meal.
        let instructionText: String?
        /// A point in the day the record itself named, e.g. "Before breakfast".
        let recordAnchor: String?
        /// Times already taken by this person's other reminders, so the model can space around
        /// them rather than stacking everything at 8am.
        let existingTimes: [DateComponents]
        /// Routine the user has told Nudgy, e.g. "mornings are rough". Never clinical.
        let statedRoutine: String?
    }

    struct Bounds {
        /// Reminders land inside waking hours. Not a clinical rule — just not waking someone at
        /// 3am because the model lost the plot.
        var earliestHour = 7
        var latestHour = 22
        /// Doses this close together are almost certainly a mistake.
        var minimumSpacingMinutes = 45

        init() {}
    }

    var bounds = Bounds()

    init(bounds: Bounds = Bounds()) {
        self.bounds = bounds
    }

    // MARK: - Prompting

    /// The instruction sent to the model. One time per line, nothing else — the narrower the
    /// output shape, the less there is to parse wrong.
    func prompt(for request: Request) -> String {
        var lines: [String] = [
            "Choose \(request.timesPerDay) reminder time\(request.timesPerDay == 1 ? "" : "s") "
                + "for a medication called \(request.itemName).",
            "",
            "Rules:",
            "- Reply with ONLY the times, one per line, in 24-hour HH:MM format.",
            "- No words, no explanation, no numbering.",
            "- Times must be between \(String(format: "%02d:00", bounds.earliestHour)) and "
                + "\(String(format: "%02d:00", bounds.latestHour)).",
            "- Spread them sensibly across the day."
        ]

        if let instruction = request.instructionText {
            lines.append("- The instruction on the record reads: \"\(instruction)\"")
        }
        if let anchor = request.recordAnchor {
            lines.append("- The record ties this to: \(anchor). Respect that.")
        }
        if !request.existingTimes.isEmpty {
            let formatted = request.existingTimes.compactMap(Self.format).joined(separator: ", ")
            lines.append("- Other reminders already exist at: \(formatted). "
                + "Avoid landing on top of them.")
        }
        if let routine = request.statedRoutine {
            lines.append("- The person mentioned: \"\(routine)\". Take it into account.")
        }

        lines.append("")
        lines.append("Times:")
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing and validation

    /// Pulls `HH:MM` values out of whatever the model returned.
    ///
    /// Tolerant of the usual decorations — bullets, numbering, stray prose — because rejecting a
    /// good answer over a leading hyphen just means falling back for no reason.
    static func parse(_ raw: String) -> [DateComponents] {
        let pattern = #"(?<!\d)([01]?\d|2[0-3])\s*:\s*([0-5]\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(raw.startIndex..., in: raw)

        return regex.matches(in: raw, range: range).compactMap { match in
            guard let hourRange = Range(match.range(at: 1), in: raw),
                  let minuteRange = Range(match.range(at: 2), in: raw),
                  let hour = Int(raw[hourRange]),
                  let minute = Int(raw[minuteRange]) else { return nil }
            return DateComponents(hour: hour, minute: minute)
        }
    }

    enum Rejection: Equatable {
        case wrongCount(expected: Int, got: Int)
        case outsideWakingHours(String)
        case tooClose(String, String)
    }

    /// Checks the model's answer. Returns nil when it is usable.
    func validate(_ times: [DateComponents], expecting count: Int) -> Rejection? {
        guard times.count == count else {
            return .wrongCount(expected: count, got: times.count)
        }

        let minutes = times.compactMap { component -> Int? in
            guard let hour = component.hour, let minute = component.minute else { return nil }
            return hour * 60 + minute
        }
        guard minutes.count == times.count else {
            return .wrongCount(expected: count, got: minutes.count)
        }

        for (index, value) in minutes.enumerated() {
            if value < bounds.earliestHour * 60 || value > bounds.latestHour * 60 {
                return .outsideWakingHours(Self.format(times[index]) ?? "?")
            }
        }

        let sorted = minutes.sorted()
        for pair in zip(sorted, sorted.dropFirst()) where pair.1 - pair.0 < bounds.minimumSpacingMinutes {
            return .tooClose(Self.formatMinutes(pair.0), Self.formatMinutes(pair.1))
        }
        return nil
    }

    // MARK: - Entry point

    struct Outcome {
        let times: [DateComponents]
        /// True when these came from the model rather than the deterministic floor.
        let chosenByModel: Bool
        /// Set when the model answered but its answer was refused.
        let rejection: Rejection?
    }

    /// Asks the model, checks the answer, and falls back to deterministic spacing on any problem.
    func propose(
        _ request: Request,
        using model: NudgyLanguageModel,
        fallback: [DateComponents]
    ) async -> Outcome {
        guard request.timesPerDay > 0 else {
            return Outcome(times: fallback, chosenByModel: false, rejection: nil)
        }

        do {
            let raw = try await model.completeRaw(prompt: prompt(for: request))
            let parsed = Self.parse(raw).sorted { lhs, rhs in
                ((lhs.hour ?? 0) * 60 + (lhs.minute ?? 0)) < ((rhs.hour ?? 0) * 60 + (rhs.minute ?? 0))
            }
            if let rejection = validate(parsed, expecting: request.timesPerDay) {
                return Outcome(times: fallback, chosenByModel: false, rejection: rejection)
            }
            return Outcome(times: parsed, chosenByModel: true, rejection: nil)
        } catch {
            // Unavailable, slow, or failed. The floor holds.
            return Outcome(times: fallback, chosenByModel: false, rejection: nil)
        }
    }

    // MARK: - Formatting

    static func format(_ components: DateComponents) -> String? {
        guard let hour = components.hour, let minute = components.minute else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    static func formatMinutes(_ total: Int) -> String {
        String(format: "%02d:%02d", total / 60, total % 60)
    }
}

extension NudgyLanguageModel {
    /// Raw completion, bypassing narration.
    ///
    /// Used only for structured output that the app parses rather than shows. Anything a person
    /// reads goes through `narrate` so SafetyGuard sees it; this path is validated by schema
    /// instead. Models that cannot do this — the scripted fallback — throw, and callers use their
    /// deterministic floor.
    func completeRaw(prompt: String) async throws -> String {
        throw NudgyModelError.rawCompletionUnsupported
    }
}

enum NudgyModelError: Error, LocalizedError {
    case rawCompletionUnsupported

    var errorDescription: String? {
        switch self {
        case .rawCompletionUnsupported:
            return "This model does not support raw completions."
        }
    }
}
