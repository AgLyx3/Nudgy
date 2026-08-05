import Foundation

// Machine-readable run summaries.
//
// These exist so the guard corpora produce a *metric*, not just a green tick. A suite that only
// says "42 tests passed" cannot answer the question that matters — "is the guard getting stricter or
// looser?" — and per-rule recall is exactly the number that moves when someone edits a phrase list.

/// One case's outcome.
public struct CaseResult: Codable, Sendable {
    public let id: String
    public let corpus: String
    public let tags: [String]
    /// Expected `SafetyRule.rawValue`, or nil for must-allow cases.
    public let expectedRule: String?
    public let expectedDecision: String
    public let actualRule: String?
    public let actualDecision: String
    public let actualEvidence: String?
    public let passed: Bool
    /// Set when `passed` is false.
    public let failureDetail: String?

    public init(
        id: String,
        corpus: String,
        tags: [String],
        expectedRule: String?,
        expectedDecision: String,
        actualRule: String?,
        actualDecision: String,
        actualEvidence: String?,
        passed: Bool,
        failureDetail: String?
    ) {
        self.id = id
        self.corpus = corpus
        self.tags = tags
        self.expectedRule = expectedRule
        self.expectedDecision = expectedDecision
        self.actualRule = actualRule
        self.actualDecision = actualDecision
        self.actualEvidence = actualEvidence
        self.passed = passed
        self.failureDetail = failureDetail
    }
}

/// Per-rule confusion counts.
///
/// `falsePositives` is the count of must-allow cases this rule wrongly fired on. It is reported
/// per rule because that is the actionable form: "the advice phrase list started eating attributed
/// sentences" is a fixable statement, "safety got worse" is not.
public struct RuleScore: Codable, Sendable {
    public let rule: String
    public let expectedRejections: Int
    public let caughtRejections: Int
    public let missedRejections: Int
    public let falsePositives: Int

    public var recall: Double {
        expectedRejections == 0 ? 1.0 : Double(caughtRejections) / Double(expectedRejections)
    }
}

public struct EvalReport: Codable, Sendable {
    public let generatedAt: Date
    public let suite: String
    public let totalCases: Int
    public let passed: Int
    public let failed: Int
    /// Must-allow cases the guard rejected. The over-rejection number.
    public let falsePositiveCount: Int
    /// Must-reject cases the guard let through. The dangerous number.
    public let missedRejectionCount: Int
    public let ruleScores: [RuleScore]
    public let results: [CaseResult]

    public init(suite: String, results: [CaseResult], allRuleNames: [String]) {
        self.generatedAt = Date()
        self.suite = suite
        self.totalCases = results.count
        self.passed = results.filter(\.passed).count
        self.failed = results.filter { !$0.passed }.count
        self.falsePositiveCount = results.filter {
            $0.expectedDecision == "allowed" && $0.actualDecision == "rejected"
        }.count
        self.missedRejectionCount = results.filter {
            $0.expectedDecision == "rejected" && $0.actualDecision == "allowed"
        }.count
        self.results = results

        self.ruleScores = allRuleNames.map { rule in
            let expected = results.filter { $0.expectedRule == rule }
            let caught = expected.filter { $0.actualRule == rule }
            let missed = expected.filter { $0.actualRule != rule }
            let falsePositives = results.filter {
                $0.expectedDecision == "allowed" && $0.actualRule == rule
            }
            return RuleScore(
                rule: rule,
                expectedRejections: expected.count,
                caughtRejections: caught.count,
                missedRejections: missed.count,
                falsePositives: falsePositives.count
            )
        }
    }

    /// Writes `reports/<suite>.json`. Best-effort: a report that cannot be written must never fail
    /// the suite, because the assertions are the test and this is diagnostics.
    @discardableResult
    public func write() -> URL? {
        let directory = Fixtures.reportsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(suite).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return nil }
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }

    /// Short console summary, printed at the end of a run.
    public var consoleSummary: String {
        var lines = [
            "── \(suite) ─────────────────────────────",
            "cases: \(totalCases)   passed: \(passed)   failed: \(failed)",
            "missed rejections (unsafe): \(missedRejectionCount)",
            "false positives (over-strict): \(falsePositiveCount)",
        ]
        let exercised = ruleScores.filter { $0.expectedRejections > 0 }
        if !exercised.isEmpty {
            lines.append("per-rule recall:")
            for score in exercised.sorted(by: { $0.rule < $1.rule }) {
                let percent = Int((score.recall * 100).rounded())
                let fp = score.falsePositives > 0 ? "  (+\(score.falsePositives) false pos)" : ""
                lines.append("  \(score.rule): \(score.caughtRejections)/\(score.expectedRejections) = \(percent)%\(fp)")
            }
        }
        let unexercised = ruleScores.filter { $0.expectedRejections == 0 }.map(\.rule).sorted()
        if !unexercised.isEmpty {
            lines.append("rules with NO must-reject case: \(unexercised.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}
