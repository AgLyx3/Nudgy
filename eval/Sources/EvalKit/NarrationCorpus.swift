import Foundation

// The fixture format shared by the Swift evals and the Python judge.
//
// One schema, two consumers. `Tests/GuardEvalTests` decodes these into `SafetyRule` assertions;
// `judge/run.py` reads the same files to build judge prompts. Anything that drifts between the two
// is a bug in one of them, not two independent formats to keep in sync.

/// What a case asserts about `SafetyGuard.review`.
public struct ExpectedVerdict: Codable, Hashable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case allowed
        case rejected
    }

    public let decision: Decision

    /// `SafetyRule.rawValue`. Required for `rejected`, must be absent for `allowed`.
    ///
    /// A string rather than the enum so this target stays free of Core, and so a fixture naming a
    /// rule that no longer exists fails loudly in the test that maps it instead of failing to
    /// decode here.
    public let rule: String?

    /// Substring the verdict's `evidence` must contain.
    ///
    /// A substring rather than an exact match on purpose: evidence is trimmed and canonicalised
    /// inside the guard, and pinning the exact string would make every fixture brittle against
    /// harmless formatting changes. It still has to name the offending token, which is the part
    /// that matters.
    public let evidenceContains: String?

    /// Asserted only when non-nil, since most allowed cases do not care.
    public let didTrim: Bool?
}

/// One authored narration case.
public struct NarrationCase: Codable, Hashable, Identifiable, Sendable {
    public let id: String

    /// Why this case exists — the failure it is guarding against. Printed on failure, so a red test
    /// explains itself without anyone having to reconstruct the intent.
    public let rationale: String

    /// The `GroundingContext` facts, in the same shape `GroundedPromptBuilder` emits
    /// (`"Name: Lisinopril"`, `"Reminder 1 of 2 - Morning: 8:00 AM [From your record]"`, …).
    public let facts: [String]

    /// The candidate model output under review.
    public let candidate: String

    public let expect: ExpectedVerdict

    /// Free-form labels for slicing the report (`"grounding"`, `"tone"`, `"attribution"`).
    public let tags: [String]

    /// Overrides the guard's default sentence budget. Only set it for cases about trimming.
    public let maxSentences: Int?
}

/// A corpus file: one intent, many cases.
public struct NarrationCorpus: Codable, Sendable {
    public let schemaVersion: Int
    /// Human label, e.g. `"must-reject"`.
    public let corpus: String
    public let description: String

    /// `"assert"` (default) or `"known-limitation"`.
    ///
    /// A known-limitation corpus documents output the guard *currently* gets wrong. Those cases are
    /// asserted to keep failing, so the defect is recorded and measurable without turning the suite
    /// red — and the day someone fixes the guard, the assertion flips and says so. The alternative
    /// (deleting the case, or leaving it failing) either hides the bug or trains people to ignore a
    /// red build.
    public let kind: String?

    public var isKnownLimitation: Bool { kind == "known-limitation" }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, corpus, description, kind, cases
    }
    public let cases: [NarrationCase]
}

// MARK: - Loading

public enum FixtureError: Error, CustomStringConvertible {
    case directoryNotFound(String)
    case fileNotFound(String)
    case duplicateCaseIDs([String])

    public var description: String {
        switch self {
        case .directoryNotFound(let path):
            return "Fixture directory not found at \(path). Set NUDGY_EVAL_FIXTURES to override."
        case .fileNotFound(let path):
            return "Fixture file not found: \(path)"
        case .duplicateCaseIDs(let ids):
            return "Duplicate case ids (they must be unique across all corpora): \(ids.joined(separator: ", "))"
        }
    }
}

public enum Fixtures {

    /// The `eval/fixtures` directory.
    ///
    /// Derived from `#filePath` rather than `Bundle` because SwiftPM test bundles do not carry
    /// arbitrary sibling directories, and because deriving it from source location means the evals
    /// work identically under `swift test`, Xcode, and CI with no resource copying step.
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["NUDGY_EVAL_FIXTURES"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        // .../eval/Sources/EvalKit/NarrationCorpus.swift → .../eval
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EvalKit
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // eval
            .appendingPathComponent("fixtures", isDirectory: true)
    }

    /// Where test runs write their machine-readable summaries.
    public static var reportsDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["NUDGY_EVAL_REPORTS"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return root.deletingLastPathComponent().appendingPathComponent("reports", isDirectory: true)
    }

    /// Loads `fixtures/narration/<name>.json`.
    public static func narrationCorpus(_ name: String) throws -> NarrationCorpus {
        let directory = root.appendingPathComponent("narration", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw FixtureError.directoryNotFound(directory.path)
        }
        let url = directory.appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureError.fileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(NarrationCorpus.self, from: data)
    }

    /// Every narration corpus on disk, sorted by filename so runs are reproducible.
    public static func allNarrationCorpora() throws -> [NarrationCorpus] {
        let directory = root.appendingPathComponent("narration", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw FixtureError.directoryNotFound(directory.path)
        }
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
        return try names.map { try narrationCorpus($0) }
    }

    /// Fails if two cases anywhere share an id.
    ///
    /// Ids are the join key between the Swift evals, the judge's output, and the calibration set.
    /// A silent duplicate would make one of them overwrite the other's result.
    public static func assertUniqueIDs(_ corpora: [NarrationCorpus]) throws {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for corpus in corpora {
            for testCase in corpus.cases {
                if !seen.insert(testCase.id).inserted { duplicates.insert(testCase.id) }
            }
        }
        guard duplicates.isEmpty else {
            throw FixtureError.duplicateCaseIDs(duplicates.sorted())
        }
    }
}
