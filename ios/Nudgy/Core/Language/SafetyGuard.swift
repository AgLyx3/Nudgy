import Foundation

// MARK: - Verdict

/// Which rule fired. Surfaced in Settings so a rejection is an observable event rather than a
/// mysteriously bland sentence.
enum SafetyRule: String, Codable, Hashable, CaseIterable {
    case imperativeClinicalAdvice
    case unattributedAdministrationInstruction
    case ungroundedClockTime
    case ungroundedNumber
    case ungroundedQuantity
    case ungroundedTimeAnchor
    case diagnosisOrTriage
    case emptyOutput
    case malformedOutput

    var title: String {
        switch self {
        case .imperativeClinicalAdvice: return "Told the user what to do"
        case .unattributedAdministrationInstruction: return "Gave an instruction without citing the record"
        case .ungroundedClockTime: return "Invented a time of day"
        case .ungroundedNumber: return "Invented a number"
        case .ungroundedQuantity: return "Invented a dose or quantity"
        case .ungroundedTimeAnchor: return "Invented a timing anchor"
        case .diagnosisOrTriage: return "Diagnosis or triage language"
        case .emptyOutput: return "Produced nothing usable"
        case .malformedOutput: return "Leaked prompt scaffolding"
        }
    }

    /// Why the rule exists. Written for a human reading Settings, not for a log parser.
    var rationale: String {
        switch self {
        case .imperativeClinicalAdvice:
            return "v1 never tells anyone what to take or when. That is the care team's job, and the design doc lists it as out of scope."
        case .unattributedAdministrationInstruction:
            return "Restating a dosing instruction is fine when it is quoted from the record. Asserting one as Nudgy's own is advice."
        case .ungroundedClockTime:
            return "Charts rarely state a time of day. A model that supplies one has invented the single most consequential field in a medication reminder."
        case .ungroundedNumber:
            return "Every number a reminder shows must trace to the record. An unsourced number is a dose, a frequency, or a duration that nobody prescribed."
        case .ungroundedQuantity:
            return "The number was in the record but paired with a different unit — '10 repetitions' becoming '10 mg' reads fluently and is completely wrong."
        case .ungroundedTimeAnchor:
            return "'With meals', 'at bedtime' and 'in the morning' are clinical instructions when the record did not say them."
        case .diagnosisOrTriage:
            return "Diagnosis and urgent triage are explicitly excluded from v1. Nudgy must not be the thing that decides whether something is an emergency."
        case .emptyOutput:
            return "A blank or near-blank generation is a failure, not a calm pause."
        case .malformedOutput:
            return "Prompt scaffolding in the output means the model lost the frame; nothing after that point is trustworthy."
        }
    }
}

/// The result of reviewing one generation.
struct SafetyVerdict: Hashable {
    enum Decision: String, Hashable { case allowed, rejected }

    let decision: Decision
    let rule: SafetyRule?
    /// What tripped the rule.
    ///
    /// This is safe to persist and display locally: for phrase rules it is a fixed string from
    /// Nudgy's own rule table, and for grounding rules it is by definition a token that does *not*
    /// appear in the record. Neither can carry PHI, which is what lets Settings show real
    /// diagnostics instead of an opaque counter.
    let evidence: String?
    /// The text that is safe to display. Meaningful only when `decision == .allowed`.
    let sanitizedText: String
    /// True when the reply was longer than the allowed sentence count and was shortened.
    let didTrim: Bool
    let reviewedAt: Date

    static func allowed(text: String, didTrim: Bool) -> SafetyVerdict {
        SafetyVerdict(decision: .allowed, rule: nil, evidence: nil,
                      sanitizedText: text, didTrim: didTrim, reviewedAt: Date())
    }

    static func rejected(_ rule: SafetyRule, evidence: String?) -> SafetyVerdict {
        SafetyVerdict(decision: .rejected, rule: rule, evidence: evidence,
                      sanitizedText: "", didTrim: false, reviewedAt: Date())
    }

    /// One line for the Settings list.
    var summary: String {
        switch decision {
        case .allowed:
            return didTrim ? "Allowed (shortened to fit)" : "Allowed"
        case .rejected:
            guard let rule else { return "Rejected" }
            if let evidence { return "\(rule.title) — \(evidence)" }
            return rule.title
        }
    }
}

// MARK: - The guard

/// Post-generation filter. Nothing the model writes reaches the timeline without passing through
/// here first.
///
/// ## Why this is a filter and not a prompt
///
/// The system prompt already says "never give medical advice". Models comply with that most of
/// the time, and "most of the time" is not a safety property. This file is the part that is
/// actually true: it is deterministic, it is testable without a GPU, and it fails closed — every
/// rejection swaps in the deterministic template, so the user still gets a correct, cited
/// reminder. The worst case of a false positive is a slightly less warm sentence. The worst case
/// of a false negative is a fabricated dose on a medication reminder. The asymmetry is total, and
/// every judgement call below is resolved in that direction.
///
/// ## The three rules
///
/// 1. **Imperative clinical advice** — Nudgy may restate, attribute, and hedge. It may not
///    instruct. Split into an absolute tier (never acceptable in any framing) and an
///    attribution-gated tier (acceptable only when clearly quoted from the record), because
///    "Your record says to take it with meals" is exactly the sentence we want and
///    "Take it with meals" is exactly the sentence we forbid — the difference is attribution,
///    not vocabulary.
///
/// 2. **Ungrounded numbers, clock times, quantities and timing anchors.** The highest-consequence
///    hallucination class, so it gets the most machinery. See `checkGrounding` for the full
///    treatment of the "innocuous number" problem.
///
/// 3. **Diagnosis and triage.** Absolute; no attribution can rescue it. A chart does not say
///    "you may have"; a model does.
enum SafetyGuard {

    // MARK: Public API

    /// Reviews a complete generation.
    static func review(
        _ output: String,
        against context: GroundingContext,
        maxSentences: Int = 3
    ) -> SafetyVerdict {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty / stub output. Counted in *letters*, not characters, because the failure mode that
        // actually happens is a decoder emitting "..." or "—" and stopping, which is three
        // characters of nothing. The shortest reply Nudgy would ever legitimately make ("Okay,
        // that's set.") clears both thresholds comfortably.
        let letterCount = trimmed.filter { $0.isLetter }.count
        guard trimmed.count >= 8, letterCount >= 4 else {
            return .rejected(.emptyOutput, evidence: "\(letterCount) letters")
        }

        // Scaffolding leakage. Once chat-template tokens or role labels appear, the model is no
        // longer answering — it is continuing the transcript, and may be writing our own
        // "Bad:" few-shot examples back at us.
        for marker in scaffoldingMarkers where trimmed.lowercased().contains(marker) {
            return .rejected(.malformedOutput, evidence: marker)
        }

        let sentences = self.sentences(in: trimmed)

        // Rules 1 and 3 are sentence-scoped, because attribution is a property of a sentence.
        for sentence in sentences {
            let phrase = phraseForm(of: sentence)
            let attributed = isAttributed(sentence: sentence, phrase: phrase, context: context)

            if let hit = firstMatch(in: phrase, among: triagePhrases) {
                return .rejected(.diagnosisOrTriage, evidence: hit.trimmingCharacters(in: .whitespaces))
            }
            if let hit = firstMatch(in: phrase, among: absoluteAdvicePhrases) {
                return .rejected(.imperativeClinicalAdvice, evidence: hit.trimmingCharacters(in: .whitespaces))
            }
            if !attributed, let hit = firstMatch(in: phrase, among: attributionGatedPhrases) {
                return .rejected(.unattributedAdministrationInstruction,
                                 evidence: hit.trimmingCharacters(in: .whitespaces))
            }
        }

        // Rule 2 is document-scoped for numbers (a number is grounded or it is not, wherever it
        // appears) and sentence-scoped for timing anchors (negated sentences are exempt).
        if let verdict = checkGrounding(sentences: sentences, whole: trimmed, context: context) {
            return verdict
        }

        // Length. Deliberately *not* a rejection: a calm, correct, four-sentence reply is not a
        // safety failure, it is a style failure, and throwing it away for the template would make
        // the product worse without making it safer. Trim and record that we did.
        if sentences.count > maxSentences {
            let kept = sentences.prefix(maxSentences)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            return .allowed(text: kept, didTrim: true)
        }

        return .allowed(text: trimmed, didTrim: false)
    }

    /// Cheap check against a partially generated buffer, for early abort during streaming.
    ///
    /// Runs only the phrase rules, and only those, because grounding cannot be judged on a prefix
    /// — "50" is grounded until it becomes "500". Returns nil to mean "nothing definitive yet",
    /// never "safe": `review` remains the authoritative call.
    static func partialTripwire(_ partial: String, against context: GroundingContext) -> SafetyVerdict? {
        let phrase = phraseForm(of: partial)
        if let hit = firstMatch(in: phrase, among: triagePhrases) {
            return .rejected(.diagnosisOrTriage, evidence: hit.trimmingCharacters(in: .whitespaces))
        }
        if let hit = firstMatch(in: phrase, among: absoluteAdvicePhrases) {
            return .rejected(.imperativeClinicalAdvice, evidence: hit.trimmingCharacters(in: .whitespaces))
        }
        if partial.lowercased().contains("<start_of_turn>") || partial.lowercased().contains("<end_of_turn>") {
            return .rejected(.malformedOutput, evidence: "chat template token")
        }
        return nil
    }

    // MARK: - Rule 2: grounding

    /// Numbers, clock times, quantities and timing anchors must all trace to the context.
    ///
    /// ## The innocuous-number problem, and why there is no allowlist
    ///
    /// Some numbers in a reminder are not clinical: "dose 1 of 2", "the 2nd reminder", "3 of your
    /// records". The obvious fix is to exempt those shapes. The obvious fix is wrong: any
    /// exemption keyed on surface form is a hole, and generations walk through holes. Exempt
    /// `\d+ of \d+` and "take 1 of 2 extra tablets" becomes legal. Exempt ordinals and "1st thing
    /// in the morning, 500 mg" needs only a comma to slip through.
    ///
    /// So Nudgy makes the innocuous numbers **grounded rather than exempt**.
    /// `GroundedPromptBuilder` emits the slot count, every slot label ("Dose 1 of 2"), the
    /// numeric form of the frequency, and the formatted times as explicit labelled fields. They
    /// are in the corpus, so they pass the same check as everything else, and 850 still fails.
    /// The cost is a real one and worth stating: the guard is only as permissive as the builder
    /// is thorough, and a number the builder forgets to emit will cause a false rejection — a
    /// slightly flat sentence. That is the correct direction to fail in.
    ///
    /// Two further softenings, both narrow and both deliberate:
    ///
    /// - **Number words count as numbers.** "twice daily" and "2 times daily" produce the same
    ///   tokens, so the model may paraphrase the record's cadence without tripping the guard,
    ///   but may not change it. "three times daily" against a "twice daily" record still fails.
    /// - **Negated sentences are exempt from the *anchor* rule only.** "Your record does not say
    ///   anything about meals" must be sayable; "take it with meals" must not. Numbers stay
    ///   strict even under negation, because a negated invented dose is still an invented dose
    ///   sitting on the user's screen.
    private static func checkGrounding(
        sentences: [String],
        whole: String,
        context: GroundingContext
    ) -> SafetyVerdict? {
        let allowed = tokens(in: context.corpus)
        let produced = tokens(in: whole)

        // Clock times are judged per sentence, on attribution rather than vocabulary.
        //
        // Nudgy is expected to choose reminder times, so "I've set this for 9:30 — your other two
        // are at 8:00 and I didn't want them stacked" is the product working. What stays forbidden
        // is "your chart says to take this at 9:30", which is a fabricated prescription. The
        // difference is who the sentence credits, not whether a number appears in it.
        for sentence in sentences {
            let phrase = phraseForm(of: sentence)
            if attributesToRecord(phrase) {
                // Credited to the record: every clock time in it must actually be in the record.
                let inSentence = tokens(in: sentence)
                for time in inSentence.clockTimes.sorted() where !allowed.clockTimes.contains(time) {
                    return .rejected(.ungroundedClockTime, evidence: time)
                }
                continue
            }
            if isNudgyOffer(phrase) || isNegatedRecordStatement(phrase) { continue }
            let inSentence = tokens(in: sentence)
            for time in inSentence.clockTimes.sorted() where !allowed.clockTimes.contains(time) {
                return .rejected(.ungroundedClockTime, evidence: time)
            }
        }
        for number in produced.numbers.sorted() where !allowed.numbers.contains(number) {
            // A number bound to a duration unit, in a sentence where Nudgy is describing its own
            // schedule, is spacing arithmetic rather than a clinical quantity: "I've put these
            // twelve hours apart" is Nudgy explaining itself. Dose units are untouched, so
            // "850 mg" is still rejected under any framing — see `ungroundedQuantity`.
            if isSchedulingDuration(number, in: sentences) { continue }
            return .rejected(.ungroundedNumber, evidence: number)
        }
        for pair in produced.quantities.sorted() where !allowed.quantities.contains(pair) {
            // Same carve-out as numbers: a quantity whose unit is a duration is Nudgy describing
            // its own spacing, not a dose. "12 hour" passes here; "850 mg" never does, because mg
            // is not a duration unit.
            let unit = pair.split(separator: "|").last.map(String.init) ?? ""
            let value = pair.split(separator: "|").first.map(String.init) ?? ""
            if Self.durationUnits.contains(unit), isSchedulingDuration(value, in: sentences) {
                continue
            }
            return .rejected(.ungroundedQuantity, evidence: pair.replacingOccurrences(of: "|", with: " "))
        }

        for sentence in sentences {
            let phrase = phraseForm(of: sentence)
            if isNegatedRecordStatement(phrase) { continue }
            // An anchor offered as Nudgy's own idea is permitted; an anchor asserted as something
            // the chart said is not. See `isNudgyOffer` for why this distinction is the whole rule.
            if isNudgyOffer(phrase), !attributesToRecord(phrase) { continue }
            let anchors = timeAnchors(in: phrase)
            for anchor in anchors.sorted() where !allowed.timeAnchors.contains(anchor) {
                return .rejected(.ungroundedTimeAnchor, evidence: anchor)
            }
        }

        return nil
    }

    // MARK: - Tokenisation

    /// Everything countable that a piece of text asserts.
    struct Tokens: Hashable {
        var clockTimes: Set<String> = []
        var numbers: Set<String> = []
        /// "500|mg", "1|tablet", "2|time" — a number bound to the unit it was said with.
        var quantities: Set<String> = []
        var timeAnchors: Set<String> = []
    }

    /// Tokenises line by line.
    ///
    /// Per-line matters: the grounding corpus is one labelled field per line, and running the
    /// number/unit pattern across a line break would pair the "2" ending one field with the
    /// "tablet" starting the next, grounding a quantity nobody stated.
    static func tokens(in text: String) -> Tokens {
        var result = Tokens()
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let lineTokens = tokensInLine(String(line))
            result.clockTimes.formUnion(lineTokens.clockTimes)
            result.numbers.formUnion(lineTokens.numbers)
            result.quantities.formUnion(lineTokens.quantities)
            result.timeAnchors.formUnion(lineTokens.timeAnchors)
        }
        return result
    }

    private static func tokensInLine(_ text: String) -> Tokens {
        var result = Tokens()
        var working = tokenForm(of: text)

        // 1. Clock times first, and blank them out, so "8:00 AM" does not also register the bare
        //    numbers 8 and 0 — which would silently ground "8 tablets".
        for match in regexMatches(pattern: "([0-9]{1,2}):([0-9]{2})\\s*(am|pm)?", in: working).reversed() {
            let hour = group(1, of: match, in: working) ?? ""
            let minute = group(2, of: match, in: working) ?? ""
            let meridiem = group(3, of: match, in: working) ?? ""
            result.clockTimes.insert(canonicalTime(hour: hour, minute: minute, meridiem: meridiem))
            working = blank(match.range, in: working)
        }
        for match in regexMatches(pattern: "([0-9]{1,2})\\s*(am|pm)\\b", in: working).reversed() {
            let hour = group(1, of: match, in: working) ?? ""
            let meridiem = group(2, of: match, in: working) ?? ""
            result.clockTimes.insert(canonicalTime(hour: hour, minute: "00", meridiem: meridiem))
            working = blank(match.range, in: working)
        }

        // 2. Digit runs, with the word that follows them.
        for match in regexMatches(pattern: "([0-9]+(?:\\.[0-9]+)?)\\s*([a-z]+)?", in: working) {
            guard let raw = group(1, of: match, in: working) else { continue }
            let value = canonicalNumber(raw)
            result.numbers.insert(value)
            if let word = group(2, of: match, in: working), let unit = canonicalUnit(word) {
                result.quantities.insert("\(value)|\(unit)")
            }
        }

        // 3. Number words, but only in quantitative position — followed by a unit. Bare "one" in
        //    "one of your records" is prose, not a dose, and treating it as a dose would reject
        //    half of the safe copy in the design doc.
        let wordAlternatives = numberWords.keys.sorted().joined(separator: "|")
        for match in regexMatches(pattern: "\\b(\(wordAlternatives))\\s+([a-z]+)", in: working) {
            guard let word = group(1, of: match, in: working),
                  let value = numberWords[word] else { continue }
            guard let following = group(2, of: match, in: working), let unit = canonicalUnit(following) else { continue }
            result.numbers.insert(value)
            result.quantities.insert("\(value)|\(unit)")
        }

        // 4. Frequency words. "twice daily" is a number sentence wearing a disguise, and it is the
        //    single most common way a cadence gets quietly changed.
        for match in regexMatches(pattern: "\\b(once|twice|thrice)\\b\\s*([a-z]+)?", in: working) {
            guard let word = group(1, of: match, in: working),
                  let value = frequencyWords[word] else { continue }
            result.numbers.insert(value)
            result.quantities.insert("\(value)|time")
            if let following = group(2, of: match, in: working), let unit = canonicalUnit(following) {
                result.quantities.insert("\(value)|\(unit)")
            }
        }

        result.timeAnchors = timeAnchors(in: working)
        return result
    }

    /// Time-of-day anchors present in a piece of text.
    ///
    /// `food` is deliberately absent: "your record does not say anything about food" is safe copy
    /// we want, and the dangerous phrasing ("take it with food") is caught by the attribution-gated
    /// phrase rule instead. `meal` *is* present, because "with meals" is a verbatim instruction
    /// that either is or is not in the chart.
    static func timeAnchors(in text: String) -> Set<String> {
        let words = tokenForm(of: text)
            .replacingOccurrences(of: ":", with: " ")
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        var found: Set<String> = []
        for word in words {
            let stem = word.hasSuffix("s") ? String(word.dropLast()) : word
            if anchorWords.contains(stem) { found.insert(stem) }
            if anchorWords.contains(word) { found.insert(word) }
        }
        if tokenForm(of: text).contains("empty stomach") { found.insert("empty stomach") }
        return found
    }

    // MARK: - Attribution

    /// True when the sentence presents its content as coming from the record rather than from
    /// Nudgy. Either an explicit attribution phrase, or a quoted span that really is in the corpus.
    static func isAttributed(sentence: String, phrase: String, context: GroundingContext) -> Bool {
        for marker in attributionMarkers where phrase.contains(marker) { return true }
        for quoted in quotedSpans(in: sentence) {
            let normalized = phraseForm(of: quoted)
            guard normalized.count >= 8 else { continue }
            if phraseForm(of: context.corpus).contains(normalized) { return true }
        }
        return false
    }

    /// True for sentences that report an absence. These cannot smuggle an instruction, so they are
    /// exempt from the timing-anchor rule.
    static func isNegatedRecordStatement(_ phrase: String) -> Bool {
        let negations = [
            " does not say", " do not say", " did not say", " does not mention", " does not list",
            " is not in the record", " not in your record", " nothing about", " no mention of",
            " does not include", " does not tell", " is not written", " not stated",
            " does not name", " do not name", " never says"
        ]
        for negation in negations where phrase.contains(negation) { return true }
        return false
    }

    /// True when the sentence offers something as Nudgy's own idea rather than asserting it as a
    /// fact from the record.
    ///
    /// This exists because the design doc's own sanctioned copy was being rejected:
    ///
    /// > "Would you like me to remind you around breakfast and dinner?"
    /// > "Mornings look open in your calendar, so I can remind you then if that matches your routine."
    ///
    /// Both name a time anchor the chart never stated — which is exactly the point. Nudgy is
    /// *allowed* to propose convenient windows so long as it is transparent that they are its own
    /// suggestion, and the doc explicitly contrasts this with the forbidden "You should take this
    /// medication in the morning."
    ///
    /// So the anchor rule turns on **attribution, not vocabulary**. Claiming the record said
    /// "breakfast" stays a rejection; offering breakfast as a suggestion does not. Note this
    /// This gates two rules: ungrounded time *anchors* ("breakfast") and ungrounded *clock times*
    /// ("9:30"), both of which Nudgy is meant to propose. It deliberately does not relax
    /// `ungroundedNumber` or `ungroundedQuantity`: a dose is not something the model gets to pick
    /// under any framing, so "I can remind you to take 850 mg" is still rejected.
    /// Units that describe an interval rather than an amount of medicine.
    static let durationUnits: Set<String> = [
        "hour", "hours", "minute", "minutes", "min", "mins", "day", "days"
    ]

    /// True when `number` appears only as a duration ("twelve hours apart", "30 minutes later")
    /// inside sentences where Nudgy is describing the schedule it chose.
    ///
    /// Deliberately narrow. It matches the number *immediately followed by a time unit*, and only
    /// in a sentence that already reads as Nudgy's own statement. A dose never satisfies both.
    static func isSchedulingDuration(_ number: String, in sentences: [String]) -> Bool {
        let units = Self.durationUnits
        for sentence in sentences {
            let phrase = phraseForm(of: sentence)
            guard isNudgyOffer(phrase), !attributesToRecord(phrase) else { continue }
            // The tokeniser normalises "twelve" to "12" but `phraseForm` keeps the word, so match
            // either surface form against the numeric token being judged.
            let words = phrase.split(separator: " ").map(String.init)
            for (index, word) in words.enumerated() {
                let asDigits = numberWords[word] ?? word
                guard asDigits == number else { continue }
                let next = index + 1 < words.count ? words[index + 1] : ""
                if units.contains(next) { return true }
            }
        }
        return false
    }

    /// True when the sentence credits the record for something.
    ///
    /// This outranks `isNudgyOffer`, because a sentence can wear both hats: "I'll remind you at
    /// 7:30, which is when your chart says to take it" opens as an offer and closes as a
    /// fabricated prescription. The offer framing must not buy amnesty for the attribution.
    static func attributesToRecord(_ phrase: String) -> Bool {
        let attributions = [
            " chart says", " chart said", " record says", " record said",
            " records say", " notes say", " prescription says", " label says",
            " as prescribed", " your doctor says", " according to your",
            " that is when your", " which is when your"
        ]
        for attribution in attributions where phrase.contains(attribution) { return true }
        return false
    }

    static func isNudgyOffer(_ phrase: String) -> Bool {
        let offers = [
            // Every entry is written *post*-normalisation: contractions expanded, punctuation
            // flattened to spaces. An entry containing an apostrophe or a full stop can never
            // match, and fails open — the sentence is judged rather than skipped. Three such
            // entries were dead here before this was written down.
            " i can ", " i could ", " i would suggest", " i am suggesting",
            " would you like", " want me to", " shall i ", " do you want",
            " if that matches", " if that suits", " if that works", " if you like",
            " my suggestion", " i suggest", " happy to",
            // Nudgy stating what it has done or will do with the schedule it owns.
            // NOTE: `phraseForm` expands contractions before matching, so these are written in
            // expanded form. "I've set" arrives here as "i have set".
            " i have set", " i have put", " i will remind", " i have spaced",
            " i have scheduled", " i have moved", " i have picked", " i have chosen",
            " i picked", " i chose", " i set ", " i put "
        ]
        assert(
            offers.allSatisfy { !$0.contains("'") && !$0.contains(".") },
            "Offer phrases are matched after contraction expansion and punctuation flattening. "
            + "An entry with an apostrophe or full stop can never match and will fail open."
        )
        // Padded so " i can " matches at the start of a sentence too.
        let padded = " \(phrase) "
        for offer in offers where padded.contains(offer) { return true }
        return false
    }

    static func quotedSpans(in text: String) -> [String] {
        var spans: [String] = []
        for pattern in ["\"([^\"]{1,300})\"", "\u{201C}([^\u{201D}]{1,300})\u{201D}"] {
            for match in regexMatches(pattern: pattern, in: text) {
                if let value = group(1, of: match, in: text) { spans.append(value) }
            }
        }
        return spans
    }

    // MARK: - Sentence splitting

    /// Splits into sentences without breaking decimals or "a.m.".
    static func sentences(in text: String) -> [String] {
        var working = text
        working = working.replacingOccurrences(of: "a.m.", with: "am", options: .caseInsensitive)
        working = working.replacingOccurrences(of: "p.m.", with: "pm", options: .caseInsensitive)
        // Protect decimal points so "0.5 mg" is one sentence, not two.
        working = replaceMatches(pattern: "([0-9])\\.([0-9])", in: working) { groups in
            (groups[1] ?? "") + "\u{1}" + (groups[2] ?? "")
        }

        var out: [String] = []
        var current = ""
        for character in working {
            current.append(character)
            if character == "." || character == "!" || character == "?" || character == "\n" {
                out.append(current)
                current = ""
            }
        }
        out.append(current)

        return out
            .map { $0.replacingOccurrences(of: "\u{1}", with: ".").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Normalisation

    /// Form used for phrase matching: lowercased, contractions expanded, all punctuation flattened
    /// to spaces, padded with spaces at both ends.
    ///
    /// Flattening punctuation is what makes the rules tolerant of the ways a model decorates a
    /// sentence — "you should, take it" and "you should—take it" both normalise to the same thing,
    /// so a comma cannot be a bypass.
    static func phraseForm(of text: String) -> String {
        var working = text.lowercased()
        working = working.replacingOccurrences(of: "\u{2019}", with: "'")
        working = working.replacingOccurrences(of: "\u{02BC}", with: "'")
        for (contraction, expansion) in contractions {
            working = working.replacingOccurrences(of: contraction, with: expansion)
        }
        var flattened = ""
        for character in working {
            if character.isLetter || character.isNumber {
                flattened.append(character)
            } else {
                flattened.append(" ")
            }
        }
        let collapsed = flattened.split(separator: " ").joined(separator: " ")
        return " " + collapsed + " "
    }

    /// Form used for token extraction: keeps `:` and `.` so clock times and decimals survive.
    static func tokenForm(of text: String) -> String {
        var working = text.lowercased()
        working = working.replacingOccurrences(of: "\u{2019}", with: "'")
        working = working.replacingOccurrences(of: "a.m.", with: "am")
        working = working.replacingOccurrences(of: "p.m.", with: "pm")
        working = working.replacingOccurrences(of: "o'clock", with: " ")
        var flattened = ""
        for character in working {
            if character.isLetter || character.isNumber || character == ":" || character == "." {
                flattened.append(character)
            } else {
                flattened.append(" ")
            }
        }
        let collapsed = flattened.split(separator: " ").joined(separator: " ")
        return " " + collapsed + " "
    }

    static func canonicalNumber(_ raw: String) -> String {
        guard let value = Double(raw) else { return raw }
        if value == value.rounded() && abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    static func canonicalTime(hour: String, minute: String, meridiem: String) -> String {
        let hourValue = Int(hour) ?? 0
        let minuteValue = Int(minute) ?? 0
        let suffix = meridiem.isEmpty ? "" : meridiem.lowercased()
        return String(format: "%d:%02d%@", hourValue, minuteValue, suffix)
    }

    static func canonicalUnit(_ word: String) -> String? { unitCanon[word] }

    // MARK: - Regex helpers

    private static func regexMatches(pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    private static func blank(_ range: NSRange, in text: String) -> String {
        guard let swiftRange = Range(range, in: text) else { return text }
        var copy = text
        copy.replaceSubrange(swiftRange, with: String(repeating: " ", count: range.length))
        return copy
    }

    private static func replaceMatches(
        pattern: String,
        in text: String,
        transform: ([Int: String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            var groups: [Int: String] = [:]
            for index in 1..<match.numberOfRanges {
                if let range = Range(match.range(at: index), in: text) {
                    groups[index] = String(text[range])
                }
            }
            guard let full = Range(match.range, in: result) else { continue }
            result.replaceSubrange(full, with: transform(groups))
        }
        return result
    }

    private static func firstMatch(in phrase: String, among phrases: [GuardedPhrase]) -> String? {
        for candidate in phrases where phrase.contains(candidate.text) {
            if candidate.requiresClinicalObject && !mentionsClinicalObject(phrase) { continue }
            return candidate.text
        }
        return nil
    }

    private static func mentionsClinicalObject(_ phrase: String) -> Bool {
        for word in clinicalObjects where phrase.contains(" \(word) ") { return true }
        return false
    }
}

// MARK: - Rule tables

/// A phrase to match, plus whether it only counts when the sentence is talking about something
/// clinical. The gate exists so broad English ("instead of", "you should") can be caught in
/// clinical context without rejecting "you should be able to change this later".
struct GuardedPhrase {
    let text: String
    let requiresClinicalObject: Bool

    init(_ text: String, requiresClinicalObject: Bool = false) {
        self.text = text
        self.requiresClinicalObject = requiresClinicalObject
    }
}

extension SafetyGuard {

    /// Never acceptable, in any framing, attributed or not.
    ///
    /// The design doc's own worked example of unsafe v1 language — "You should take this
    /// medication in the morning." — is caught by the first entry.
    static let absoluteAdvicePhrases: [GuardedPhrase] = [
        GuardedPhrase(" you should take "),
        GuardedPhrase(" you should use "),
        GuardedPhrase(" you should start "),
        GuardedPhrase(" you should stop "),
        GuardedPhrase(" you should try "),
        GuardedPhrase(" you should be taking "),
        GuardedPhrase(" you should ", requiresClinicalObject: true),
        GuardedPhrase(" you must take "),
        GuardedPhrase(" you need to take "),
        GuardedPhrase(" you will need to take "),
        GuardedPhrase(" you ought to "),
        GuardedPhrase(" i recommend "),
        GuardedPhrase(" i would recommend "),
        GuardedPhrase(" i suggest taking "),
        GuardedPhrase(" i would suggest taking "),
        GuardedPhrase(" my advice "),
        GuardedPhrase(" it is safe to "),
        GuardedPhrase(" it is not safe to "),
        GuardedPhrase(" it is fine to "),
        GuardedPhrase(" it is okay to "),
        GuardedPhrase(" it is ok to "),
        GuardedPhrase(" you can safely "),
        GuardedPhrase(" safe to take "),
        GuardedPhrase(" perfectly safe "),
        GuardedPhrase(" stop taking "),
        GuardedPhrase(" start taking "),
        GuardedPhrase(" keep taking "),
        GuardedPhrase(" do not take "),
        GuardedPhrase(" avoid taking "),
        GuardedPhrase(" skip a dose "),
        GuardedPhrase(" skip your dose "),
        GuardedPhrase(" skip the dose "),
        GuardedPhrase(" double up "),
        GuardedPhrase(" take an extra "),
        GuardedPhrase(" take extra "),
        GuardedPhrase(" increase your dose "),
        GuardedPhrase(" decrease your dose "),
        GuardedPhrase(" increase the dose "),
        GuardedPhrase(" decrease the dose "),
        GuardedPhrase(" lower your dose "),
        GuardedPhrase(" raise your dose "),
        GuardedPhrase(" adjust your dose "),
        GuardedPhrase(" change your dose "),
        GuardedPhrase(" instead of ", requiresClinicalObject: true),
        GuardedPhrase(" the best time to take "),
        GuardedPhrase(" best taken "),
        GuardedPhrase(" it is best to take "),
        GuardedPhrase(" make sure you take "),
        GuardedPhrase(" be sure to take "),
        GuardedPhrase(" try taking "),
        GuardedPhrase(" i would take ")
    ]

    /// Administration instructions. Fine when quoted from the record, forbidden as Nudgy's own
    /// voice. A sentence containing "your record says" (or a quoted span that really is in the
    /// corpus) is exempt.
    static let attributionGatedPhrases: [GuardedPhrase] = [
        GuardedPhrase(" take it with "),
        GuardedPhrase(" take this with "),
        GuardedPhrase(" take them with "),
        GuardedPhrase(" take these with "),
        GuardedPhrase(" take one with "),
        GuardedPhrase(" take with food "),
        GuardedPhrase(" take with meals "),
        GuardedPhrase(" take it before "),
        GuardedPhrase(" take it after "),
        GuardedPhrase(" take it on "),
        GuardedPhrase(" take it at "),
        GuardedPhrase(" take this at "),
        GuardedPhrase(" take it in the "),
        GuardedPhrase(" take this in the "),
        GuardedPhrase(" take it every "),
        GuardedPhrase(" take this every "),
        GuardedPhrase(" do this before "),
        GuardedPhrase(" do these before "),
        GuardedPhrase(" do this after "),
        GuardedPhrase(" hold each stretch for ")
    ]

    /// Diagnosis and triage. No attribution rescues these.
    static let triagePhrases: [GuardedPhrase] = [
        GuardedPhrase(" you may have "),
        GuardedPhrase(" you might have "),
        GuardedPhrase(" you could have "),
        GuardedPhrase(" sounds like you have "),
        GuardedPhrase(" could be a sign "),
        GuardedPhrase(" may be a sign "),
        GuardedPhrase(" might be a sign "),
        GuardedPhrase(" is a sign of "),
        GuardedPhrase(" symptom of "),
        GuardedPhrase(" symptoms of "),
        GuardedPhrase(" side effect of "),
        GuardedPhrase(" side effects of "),
        GuardedPhrase(" diagnos"),
        GuardedPhrase(" 911 "),
        GuardedPhrase(" emergency room "),
        GuardedPhrase(" go to the er "),
        GuardedPhrase(" urgent care "),
        GuardedPhrase(" seek immediate "),
        GuardedPhrase(" seek medical attention "),
        GuardedPhrase(" seek help "),
        GuardedPhrase(" call your doctor "),
        GuardedPhrase(" call your provider "),
        GuardedPhrase(" contact your doctor immediately "),
        GuardedPhrase(" right away if you "),
        GuardedPhrase(" immediately if you "),
        GuardedPhrase(" life threatening "),
        GuardedPhrase(" overdose ")
    ]

    /// Words that make a sentence "about medicine". Gates the broad phrases above.
    static let clinicalObjects: Set<String> = [
        "dose", "doses", "dosage", "tablet", "tablets", "capsule", "capsules", "pill", "pills",
        "medication", "medications", "med", "meds", "medicine", "drug", "drugs", "prescription",
        "mg", "mcg", "ml", "milligram", "milligrams", "injection", "insulin", "inhaler",
        "exercise", "exercises", "stretch", "stretches", "reps", "repetitions", "therapy"
    ]

    /// Phrases that mark a sentence as reporting the record rather than asserting Nudgy's opinion.
    static let attributionMarkers: [String] = [
        " your chart says ", " your chart lists ", " your chart shows ", " your chart does not ",
        " your record says ", " your record lists ", " your record shows ", " your record does not ",
        " your records say ", " your records list ", " your records do not ",
        " the record says ", " the record does not ", " the record lists ",
        " your prescription says ", " the label says ", " the instruction says ",
        " the instructions say ", " according to your ", " it says ", " it lists ",
        " your care team wrote ", " the note says ", " as written ", " written on ",
        " your plan says ", " the plan says "
    ]

    /// Chat-template and role scaffolding. Presence means the frame broke.
    static let scaffoldingMarkers: [String] = [
        "<start_of_turn>", "<end_of_turn>", "<bos>", "<eos>", "```",
        "system:", "assistant:", "user:", "context:\n", "### instruction"
    ]

    static let contractions: [(String, String)] = [
        ("it's", "it is"), ("that's", "that is"), ("there's", "there is"), ("here's", "here is"),
        ("don't", "do not"), ("doesn't", "does not"), ("didn't", "did not"), ("won't", "will not"),
        ("can't", "cannot"), ("cannot", "can not"), ("shouldn't", "should not"),
        ("wouldn't", "would not"), ("couldn't", "could not"), ("isn't", "is not"),
        ("aren't", "are not"), ("wasn't", "was not"), ("weren't", "were not"),
        ("haven't", "have not"), ("hasn't", "has not"), ("hadn't", "had not"),
        ("you're", "you are"), ("you'll", "you will"), ("you've", "you have"), ("you'd", "you would"),
        ("i'd", "i would"), ("i'll", "i will"), ("i've", "i have"), ("i'm", "i am"),
        ("we'll", "we will"), ("we're", "we are"), ("they're", "they are"), ("let's", "let us")
    ]

    /// Number words that count as numbers when they sit in front of a unit.
    static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "half": "0.5"
    ]

    static let frequencyWords: [String: String] = ["once": "1", "twice": "2", "thrice": "3"]

    /// Unit synonyms collapsed to one spelling, so "500 mg" and "500 milligrams" are the same
    /// claim. `pill` folds into `tablet`: it is a plain-English restatement, not a change of
    /// meaning, and rejecting it would cost warmth for no safety.
    static let unitCanon: [String: String] = [
        "mg": "mg", "milligram": "mg", "milligrams": "mg",
        "mcg": "mcg", "microgram": "mcg", "micrograms": "mcg",
        "g": "g", "gram": "g", "grams": "g",
        "ml": "ml", "millilitre": "ml", "millilitres": "ml", "milliliter": "ml", "milliliters": "ml",
        "tablet": "tablet", "tablets": "tablet", "tab": "tablet", "tabs": "tablet",
        "pill": "tablet", "pills": "tablet",
        "capsule": "capsule", "capsules": "capsule", "cap": "capsule", "caps": "capsule",
        "dose": "dose", "doses": "dose",
        "unit": "unit", "units": "unit",
        "puff": "puff", "puffs": "puff",
        "drop": "drop", "drops": "drop",
        "spray": "spray", "sprays": "spray",
        "patch": "patch", "patches": "patch",
        "time": "time", "times": "time",
        "rep": "rep", "reps": "rep", "repetition": "rep", "repetitions": "rep",
        "set": "set", "sets": "set",
        "second": "second", "seconds": "second",
        "minute": "minute", "minutes": "minute", "min": "minute", "mins": "minute",
        "hour": "hour", "hours": "hour", "hourly": "hour", "hr": "hour", "hrs": "hour",
        "day": "day", "days": "day", "daily": "day",
        "week": "week", "weeks": "week", "weekly": "week",
        "month": "month", "months": "month", "monthly": "month",
        "year": "year", "years": "year",
        "reminder": "reminder", "reminders": "reminder"
    ]

    /// Timing anchors. Saying one of these that the chart did not say is giving timing advice.
    static let anchorWords: Set<String> = [
        "morning", "afternoon", "evening", "night", "nighttime", "overnight",
        "bedtime", "bed", "breakfast", "lunch", "dinner", "supper", "meal", "snack",
        "noon", "midday", "midnight", "sunrise", "sunset", "waking", "wake"
    ]
}
