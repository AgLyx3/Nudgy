import XCTest
import EvalKit
@testable import NudgyCore

/// Family 1 — does `SafetyGuard.review` reject what it must, and allow what it must?
///
/// Both directions run from the same loop over the same schema, because they are the same
/// measurement taken twice. Reporting only the must-reject half would let "reject everything" score
/// perfectly; reporting only the must-allow half would let "allow everything" score perfectly.
final class GuardCorpusTests: XCTestCase {

    /// Every case in every corpus, asserted individually, then summarised into a report.
    func testNarrationCorpora() throws {
        let corpora = try Fixtures.allNarrationCorpora()
        try Fixtures.assertUniqueIDs(corpora)
        XCTAssertFalse(corpora.isEmpty, "No narration corpora found at \(Fixtures.root.path)")

        var results: [CaseResult] = []

        for corpus in corpora where !corpus.isKnownLimitation {
            for testCase in corpus.cases {
                let context = GroundingContext(facts: testCase.facts)
                let verdict = SafetyGuard.review(
                    testCase.candidate,
                    against: context,
                    maxSentences: testCase.maxSentences ?? 3
                )

                let failure = mismatch(expected: testCase.expect, actual: verdict)
                results.append(
                    CaseResult(
                        id: testCase.id,
                        corpus: corpus.corpus,
                        tags: testCase.tags,
                        expectedRule: testCase.expect.rule,
                        expectedDecision: testCase.expect.decision.rawValue,
                        actualRule: verdict.rule?.rawValue,
                        actualDecision: verdict.decision.rawValue,
                        actualEvidence: verdict.evidence,
                        passed: failure == nil,
                        failureDetail: failure
                    )
                )

                if let failure {
                    XCTFail(
                        """
                        [\(corpus.corpus)] \(testCase.id)
                          why this case exists: \(testCase.rationale)
                          candidate: \(testCase.candidate)
                          \(failure)
                        """
                    )
                }
            }
        }

        let report = EvalReport(
            suite: "guard-corpus",
            results: results,
            allRuleNames: SafetyRule.allCases.map(\.rawValue)
        )
        report.write()
        print(report.consoleSummary)
    }

    /// Known limitations must keep failing in exactly the documented way.
    ///
    /// This is a ratchet, not a rug. Each case here is output the product *should* be able to
    /// produce and currently cannot. Asserting the current wrong behaviour means the defect is
    /// recorded, counted, and impossible to forget — and the moment someone fixes the guard, this
    /// test fails and tells them to promote the case into `must_allow.json`.
    ///
    /// Every case in this corpus fails in the *safe* direction: the user gets a flat template
    /// instead of a warm sentence. If one of these ever becomes a missed rejection instead, the
    /// expectation below stops matching and the suite says so.
    func testKnownLimitationsStillFailAsDocumented() throws {
        let corpora = try Fixtures.allNarrationCorpora().filter(\.isKnownLimitation)
        guard !corpora.isEmpty else { return }

        for corpus in corpora {
            for testCase in corpus.cases {
                let context = GroundingContext(facts: testCase.facts)
                let verdict = SafetyGuard.review(
                    testCase.candidate,
                    against: context,
                    maxSentences: testCase.maxSentences ?? 3
                )

                guard verdict.decision == .rejected else {
                    XCTFail(
                        """
                        FIXED — \(testCase.id) now passes the guard.
                          candidate: \(testCase.candidate)
                          This is good news. Move the case from the known-limitation corpus into
                          must_allow.json so it is protected against regressing again.
                          context: \(testCase.rationale)
                        """
                    )
                    continue
                }

                if let expectedRule = testCase.expect.rule,
                   verdict.rule?.rawValue != expectedRule {
                    XCTFail(
                        """
                        CHANGED — \(testCase.id) still fails, but for a different reason.
                          expected rule: \(expectedRule)
                          actual rule:   \(verdict.rule?.rawValue ?? "nil")
                          The documented diagnosis is now stale; re-read the guard before updating it.
                        """
                    )
                }
            }
        }
    }

    /// Meta-test: every `SafetyRule` must have at least one must-reject case.
    ///
    /// This is the test that catches the most likely real-world regression — someone adds a rule and
    /// never writes a fixture for it, so the suite stays green while the new rule is unverified.
    func testEveryRuleHasAMustRejectCase() throws {
        let corpora = try Fixtures.allNarrationCorpora()
        let exercised = Set(
            corpora
                .flatMap(\.cases)
                .filter { $0.expect.decision == .rejected }
                .compactMap(\.expect.rule)
        )
        let all = Set(SafetyRule.allCases.map(\.rawValue))
        let uncovered = all.subtracting(exercised).sorted()

        XCTAssertTrue(
            uncovered.isEmpty,
            """
            SafetyRule cases with no must-reject fixture: \(uncovered.joined(separator: ", ")).
            Add one to fixtures/narration/must_reject.json. An unexercised rule is an untested
            safety claim.
            """
        )
    }

    /// Meta-test: every fixture names a rule that still exists.
    ///
    /// Fixtures carry rule names as strings so EvalKit stays free of Core. That flexibility has a
    /// cost — a renamed rule would silently stop matching — and this is where the cost is paid.
    func testEveryFixtureRuleNameResolves() throws {
        let corpora = try Fixtures.allNarrationCorpora()
        for corpus in corpora {
            for testCase in corpus.cases {
                switch testCase.expect.decision {
                case .rejected:
                    let name = try XCTUnwrap(
                        testCase.expect.rule,
                        "\(testCase.id): a rejected case must name a rule"
                    )
                    XCTAssertNotNil(
                        SafetyRule(rawValue: name),
                        "\(testCase.id): '\(name)' is not a SafetyRule. Was it renamed?"
                    )
                case .allowed:
                    XCTAssertNil(
                        testCase.expect.rule,
                        "\(testCase.id): an allowed case must not name a rule"
                    )
                }
            }
        }
    }

    // MARK: - Comparison

    /// Returns a human-readable mismatch, or nil when the verdict matches.
    private func mismatch(expected: ExpectedVerdict, actual: SafetyVerdict) -> String? {
        switch expected.decision {
        case .allowed:
            guard actual.decision == .allowed else {
                return """
                expected: allowed
                  actual:   rejected by \(actual.rule?.rawValue ?? "?") (evidence: \(actual.evidence ?? "nil"))
                  → over-rejection. A false positive costs the user warmth; see the asymmetry note in SafetyGuard.
                """
            }
            if let expectedTrim = expected.didTrim, expectedTrim != actual.didTrim {
                return "expected didTrim: \(expectedTrim), actual: \(actual.didTrim)"
            }
            if actual.sanitizedText.isEmpty {
                return "allowed but sanitizedText was empty — nothing would reach the timeline"
            }
            return nil

        case .rejected:
            guard actual.decision == .rejected else {
                return """
                expected: rejected by \(expected.rule ?? "?")
                  actual:   ALLOWED ("\(actual.sanitizedText)")
                  → missed rejection. This is the dangerous direction.
                """
            }
            if let expectedRule = expected.rule, actual.rule?.rawValue != expectedRule {
                return """
                expected rule: \(expectedRule)
                  actual rule:   \(actual.rule?.rawValue ?? "nil") (evidence: \(actual.evidence ?? "nil"))
                  → rejected, but for the wrong reason. The diagnostic shown in Settings would be misleading.
                """
            }
            if let needle = expected.evidenceContains {
                let evidence = actual.evidence ?? ""
                if !evidence.localizedCaseInsensitiveContains(needle) {
                    return "expected evidence containing '\(needle)', actual evidence: '\(evidence)'"
                }
            }
            return nil
        }
    }
}
