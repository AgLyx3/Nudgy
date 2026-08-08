import XCTest
import EvalKit
@testable import RemliCore

/// Family 2 — does the streaming tripwire stay in step with the authoritative guard?
///
/// `SafetyGuard.partialTripwire` is a second, smaller implementation of the same policy, running on
/// a half-finished buffer so the user never watches a fabricated dose being typed out. Two
/// implementations of one policy drift. These tests are the thing that notices.
///
/// ## What is deliberately NOT asserted
///
/// The tripwire runs only the *phrase* rules. Grounding is excluded by design — "50" is grounded
/// until it becomes "500", so a prefix cannot be judged on it (see the note above
/// `partialTripwire`). Asserting that grounding violations trip early would be asserting a bug.
///
/// So instead of "every rejection must trip early", the properties below are the ones that actually
/// hold, and each one maps to a way the UI can misbehave:
///
/// 1. **No false trips.** A trip on good output means the user sees text appear and then get
///    retracted, for nothing. Checked at every word *and* every character boundary.
/// 2. **Never contradicts the guard.** If the tripwire retracts something `review` would have
///    allowed, the two have drifted and the stricter one is wrong.
/// 3. **Monotonic.** Once tripped, it stays tripped. `retracted` is final; a tripwire that
///    un-fires would let a retracted preview resume.
///
/// Earliness — how much output the tripwire actually suppresses — is measured and printed rather
/// than asserted, because the answer depends on where in the sentence the offending phrase sits.
final class TripwirePropertyTests: XCTestCase {

    // MARK: - Property 1: no false trips on good output

    func testTripwireNeverFiresOnMustAllowOutput() throws {
        let corpora = try Fixtures.allNarrationCorpora()
            .filter { !$0.isKnownLimitation && $0.corpus == "must-allow" }
        XCTAssertFalse(corpora.isEmpty, "No must-allow corpus found — property 1 would vacuously pass.")

        for corpus in corpora {
            for testCase in corpus.cases {
                let context = GroundingContext(facts: testCase.facts)

                for prefix in wordPrefixes(of: testCase.candidate) {
                    if let verdict = SafetyGuard.partialTripwire(prefix, against: context) {
                        XCTFail(
                            """
                            False trip (word boundary) — \(testCase.id)
                              tripped at: "\(prefix)"
                              rule: \(verdict.rule?.rawValue ?? "?") evidence: \(verdict.evidence ?? "nil")
                              full text: \(testCase.candidate)
                              → the user would watch this sentence appear and then vanish, for nothing.
                            """
                        )
                        break
                    }
                }

                // Stricter pass: real decoders do not emit tidy words, so check every character
                // boundary too. This is where a phrase list with an unanchored fragment shows up.
                for prefix in characterPrefixes(of: testCase.candidate) {
                    if let verdict = SafetyGuard.partialTripwire(prefix, against: context) {
                        XCTFail(
                            """
                            False trip (character boundary) — \(testCase.id)
                              tripped at: "\(prefix)"
                              rule: \(verdict.rule?.rawValue ?? "?")
                              → a mid-word prefix tripped the guard. Check for an unanchored phrase fragment.
                            """
                        )
                        break
                    }
                }
            }
        }
    }

    // MARK: - Property 2: the tripwire never contradicts the authoritative guard

    func testTripwireNeverContradictsReview() throws {
        let corpora = try Fixtures.allNarrationCorpora().filter { !$0.isKnownLimitation }

        for corpus in corpora {
            for testCase in corpus.cases {
                let context = GroundingContext(facts: testCase.facts)
                let authoritative = SafetyGuard.review(
                    testCase.candidate,
                    against: context,
                    maxSentences: testCase.maxSentences ?? 3
                )

                let tripped = wordPrefixes(of: testCase.candidate)
                    .compactMap { SafetyGuard.partialTripwire($0, against: context) }
                    .first

                guard let tripped else { continue }

                XCTAssertEqual(
                    authoritative.decision, .rejected,
                    """
                    Drift — \(testCase.id)
                      tripwire rejected mid-stream (\(tripped.rule?.rawValue ?? "?")), but review() allowed
                      the finished text. The tripwire is stricter than the policy it enforces, so this
                      sentence can never be delivered even though it is permitted.
                      text: \(testCase.candidate)
                    """
                )
            }
        }
    }

    // MARK: - Property 3: monotonicity

    func testTripwireIsMonotonic() throws {
        let corpora = try Fixtures.allNarrationCorpora()

        for corpus in corpora {
            for testCase in corpus.cases {
                let context = GroundingContext(facts: testCase.facts)
                let prefixes = wordPrefixes(of: testCase.candidate)

                guard let firstTripIndex = prefixes.firstIndex(where: {
                    SafetyGuard.partialTripwire($0, against: context) != nil
                }) else { continue }

                for index in firstTripIndex..<prefixes.count {
                    XCTAssertNotNil(
                        SafetyGuard.partialTripwire(prefixes[index], against: context),
                        """
                        Non-monotonic — \(testCase.id)
                          tripped at prefix \(firstTripIndex) then stopped tripping at \(index).
                          prefix: "\(prefixes[index])"
                          → `retracted` is meant to be final; a preview could resume after being pulled.
                        """
                    )
                }
            }
        }
    }

    // MARK: - Earliness (measured, not asserted)

    func testReportTripwireEarliness() throws {
        let corpora = try Fixtures.allNarrationCorpora()
            .filter { !$0.isKnownLimitation && $0.corpus == "must-reject" }

        var lines: [String] = ["── tripwire earliness ─────────────────────────────"]
        var caughtEarly = 0
        var notCaught = 0

        for corpus in corpora {
            for testCase in corpus.cases {
                let context = GroundingContext(facts: testCase.facts)
                let prefixes = wordPrefixes(of: testCase.candidate)
                guard let index = prefixes.firstIndex(where: {
                    SafetyGuard.partialTripwire($0, against: context) != nil
                }) else {
                    notCaught += 1
                    lines.append("  — \(testCase.id): not caught mid-stream (expected for grounding rules)")
                    continue
                }
                caughtEarly += 1
                let suppressed = 1.0 - (Double(prefixes[index].count) / Double(testCase.candidate.count))
                lines.append("  ✓ \(testCase.id): tripped at \(Int((1 - suppressed) * 100))% of the text "
                             + "(\(Int(suppressed * 100))% never shown)")
            }
        }

        lines.append("  caught mid-stream: \(caughtEarly)   only caught at completion: \(notCaught)")
        lines.append("  (grounding rules are expected in the second group — a prefix cannot be judged on them)")
        print(lines.joined(separator: "\n"))
    }

    // MARK: - Prefix helpers

    /// Cumulative word-boundary prefixes, simulating a decoder emitting word-ish chunks.
    private func wordPrefixes(of text: String) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        guard !words.isEmpty else { return [] }
        return (1...words.count).map { words.prefix($0).joined(separator: " ") }
    }

    /// Every character-boundary prefix. Stricter than any real decoder, on purpose.
    private func characterPrefixes(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        return (1...text.count).map { String(text.prefix($0)) }
    }
}
