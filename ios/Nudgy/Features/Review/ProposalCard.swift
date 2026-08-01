import SwiftUI

/// The reviewable reminder card.
///
/// Layout follows the Serene design system; the content rules are Nudgy's. Everything clinical is
/// quoted from the record and attributed. The only thing Nudgy authors is a *timing suggestion*,
/// and that is worded and coloured differently from chart facts so the two can never be confused.
///
/// Voice note: this reads like a careful friend, not a clinician. "Your chart says how often, but
/// not when" rather than "time of day not specified". Warmth is not decoration — people ignore
/// reminders that feel like paperwork, and an ignored reminder helps nobody.
struct ProposalCard: View {
    let proposal: ReminderProposal
    var onApprove: (ReminderProposal) -> Void
    var onEdit: (ReminderProposal) -> Void
    var onSkip: (ReminderProposal) -> Void

    @State private var isExpanded = false
    @State private var showSources = false
    @State private var showNotes = false
    @State private var workingSlots: [ProposedSlot]

    init(
        proposal: ReminderProposal,
        onApprove: @escaping (ReminderProposal) -> Void,
        onEdit: @escaping (ReminderProposal) -> Void,
        onSkip: @escaping (ReminderProposal) -> Void
    ) {
        self.proposal = proposal
        self.onApprove = onApprove
        self.onEdit = onEdit
        self.onSkip = onSkip
        _workingSlots = State(initialValue: proposal.slots)
    }

    private var concernFlags: [ProposalFlag] {
        proposal.flags.filter { $0.severity == .possibleConcern }
    }

    private var infoFlags: [ProposalFlag] {
        proposal.flags.filter { $0.severity == .info }
    }

    private var state: ReminderState {
        if proposal.schedulingDeclinedReason == .asNeededMedication { return .onlyWhenNeeded }
        if workingSlots.contains(where: { $0.timeOfDay == nil }) { return .needsTime }
        // A filled-in time that Nudgy chose is labelled as such, so it is never mistaken for one
        // the chart named.
        if workingSlots.contains(where: {
            if case .convenienceSuggestion = $0.provenance { return true }
            return false
        }) { return .suggested }
        return .proposed
    }

    /// The headline time.
    ///
    /// When nothing is set, this shows Nudgy's *suggestion* in muted grey rather than a placeholder
    /// dash — the card keeps an anchor, and the greyed colour plus the "Needs a time" chip both
    /// make clear the chart did not name it.
    private var headlineTime: String {
        if proposal.schedulingDeclinedReason != nil { return "Any time" }
        if let firstSet = workingSlots.compactMap(\.timeOfDay).first,
           workingSlots.allSatisfy({ $0.timeOfDay != nil }) {
            return Self.format(firstSet)
        }
        if let suggested = workingSlots.compactMap({ $0.suggestion?.clockTime }).first {
            return Self.format(suggested)
        }
        return "No time yet"
    }

    /// Every time on one line, for the collapsed state.
    private var collapsedTimesSummary: String {
        let times = workingSlots.compactMap { $0.timeOfDay.map(Self.format) }
        guard !times.isEmpty else { return "No times set yet" }
        return times.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.md) {
            header

            Text(proposal.title)
                .font(NudgyTheme.Typeface.titleLarge())
                .foregroundStyle(NudgyTheme.Palette.onSurface)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = proposal.subtitle {
                Text(subtitle)
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !isExpanded, workingSlots.count > 1 {
                Text(collapsedTimesSummary)
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)
            }

            // A possible concern is the reason a human is needed here, so it never collapses.
            ForEach(concernFlags) { flag in
                FlagRow(flag: flag)
            }

            if isExpanded {
                expandedBody
            }

            actionRow
        }
        .padding(NudgyTheme.Metric.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nudgyCard()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: NudgyTheme.Metric.xs) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: NudgyTheme.Metric.xs) {
                    Text(headlineTime)
                        .font(NudgyTheme.Typeface.displayLarge())
                        .foregroundStyle(
                            // Sage only when the chart named the time. Nudgy's own picks stay muted.
                            state == .proposed || state == .onlyWhenNeeded
                                ? NudgyTheme.Palette.primary
                                : NudgyTheme.Palette.onSurfaceMuted
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide details" : "Show times and details")

            Spacer(minLength: NudgyTheme.Metric.xs)

            StatusChip(state: state)
        }
    }

    // MARK: - Expanded

    @ViewBuilder
    private var expandedBody: some View {
        if let declined = proposal.schedulingDeclinedReason {
            declinedNotice(declined)
        } else if !workingSlots.isEmpty {
            slotSection
        }

        if !infoFlags.isEmpty { notesDisclosure }
        sourceDisclosure
    }

    /// Shown when the engine deliberately refused to schedule — usually an as-needed medication.
    /// Declining is correct behaviour, so it reads as a considered choice rather than a failure.
    private func declinedNotice(_ reason: ReviewReason) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 14))
                .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(reason == .asNeededMedication
                     ? "This one's only when you need it."
                     : "I'll leave this one alone for now.")
                    .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                    .foregroundStyle(NudgyTheme.Palette.onSurface)

                Text(friendlyReason(reason))
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NudgyTheme.Metric.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            NudgyTheme.Palette.surfaceLow,
            in: RoundedRectangle(cornerRadius: NudgyTheme.Metric.radiusMedium)
        )
    }

    /// Warmer phrasings of the review reasons. The facts are unchanged — only the register is.
    private func friendlyReason(_ reason: ReviewReason) -> String {
        switch reason {
        case .asNeededMedication:
            return "Your chart lists it as something you take when you need it, so I won't keep pinging you about it."
        case .frequencyNotSpecified:
            return "Your chart doesn't say how often, and I'd rather ask than guess."
        case .timeOfDayNotSpecified:
            return "Your chart doesn't say when."
        case .conflictingFoodInstruction:
            return "Two of your records describe this differently."
        case .therapyDetailIncomplete:
            return "Your chart names it but doesn't describe how to do it."
        case .equipmentUnclear:
            return "Your chart doesn't mention what you'd need for it."
        case .remindersCluster:
            return "A few reminders would land close together."
        }
    }

    /// True when every unset slot is unset for the same reason — so the caveat is said once for
    /// the section rather than repeated under each dose.
    private var sharedTimingCaveat: String? {
        let unset = workingSlots.filter { $0.timeOfDay == nil }
        guard !unset.isEmpty else { return nil }
        let allNeedTime = unset.allSatisfy {
            if case .needsReview(.timeOfDayNotSpecified) = $0.provenance { return true }
            return false
        }
        guard allNeedTime else { return nil }
        return "Your chart says how often, but not when."
    }

    private var hasSuggestedTimes: Bool {
        workingSlots.contains {
            if case .convenienceSuggestion = $0.provenance { return $0.timeOfDay != nil }
            return false
        }
    }

    private var slotSection: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
            if hasSuggestedTimes {
                Text("Your chart says how often, but not when — so these times are mine, not your "
                     + "doctor's. Move any of them to whatever fits your day.")
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }

            if let caveat = sharedTimingCaveat {
                Text(caveat)
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }

            ForEach($workingSlots) { $slot in
                SlotRow(slot: $slot, suppressSupportingText: sharedTimingCaveat != nil)
            }
        }
    }

    // MARK: - Disclosures

    private var notesDisclosure: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
            disclosureButton(
                isOpen: showNotes,
                openLabel: "Hide notes",
                closedLabel: "\(infoFlags.count) note\(infoFlags.count == 1 ? "" : "s") about timing",
                tint: NudgyTheme.Palette.onSurfaceVariant
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { showNotes.toggle() }
            }

            if showNotes {
                VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
                    ForEach(infoFlags) { flag in FlagRow(flag: flag) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// The product's core affordance: every clinical claim traceable to its source, in one tap.
    private var sourceDisclosure: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
            disclosureButton(
                isOpen: showSources,
                openLabel: "Hide where this came from",
                closedLabel: "Where did this come from?",
                tint: NudgyTheme.Palette.primary
            ) {
                withAnimation(.easeInOut(duration: 0.2)) { showSources.toggle() }
            }

            if showSources {
                VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
                    ForEach(proposal.sourceFacts) { fact in
                        VerbatimQuote(
                            label: fact.label,
                            text: fact.verbatim,
                            citation: fact.citation
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func disclosureButton(
        isOpen: Bool,
        openLabel: String,
        closedLabel: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                Text(isOpen ? openLabel : closedLabel)
            }
            .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private var canApprove: Bool {
        if proposal.schedulingDeclinedReason != nil { return true }
        return !workingSlots.contains { $0.timeOfDay == nil }
    }

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
            if !canApprove {
                Text("Pick a time and I'll take it from there.")
                    .font(NudgyTheme.Typeface.labelMedium())
                    .foregroundStyle(NudgyTheme.Palette.concern)
            }

            Divider()
                .overlay(NudgyTheme.Palette.outlineVariant.opacity(0.4))
                .padding(.bottom, 2)

            HStack(spacing: NudgyTheme.Metric.xs) {
                Button(proposal.schedulingDeclinedReason != nil ? "Keep it" : "Approve") {
                    var approved = proposal
                    approved.slots = workingSlots
                    onApprove(approved)
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: .infinity)
                .disabled(!canApprove)
                .opacity(canApprove ? 1 : 0.4)

                Button(isExpanded ? "Done" : "Edit times") {
                    withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
                }
                .buttonStyle(OutlineButtonStyle())
                .frame(maxWidth: .infinity)

                // Skipping is a normal choice, not a failure, so it stays muted rather than the
                // mockup's error red — red is reserved for things that actually went wrong.
                // Borderless like the mockup, but muted rather than error-red: skipping a
                // reminder is a normal choice, and red is reserved for things that went wrong.
                Button("Skip") { onSkip(proposal) }
                    .buttonStyle(QuietButtonStyle())
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 2)
    }

    static func format(_ components: DateComponents) -> String {
        guard let hour = components.hour, let minute = components.minute,
              let date = Calendar.current.date(
                from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)
              ) else { return "—:—" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// One proposed time. Renders differently depending on where the time came from.
private struct SlotRow: View {
    @Binding var slot: ProposedSlot
    var suppressSupportingText: Bool = false

    @State private var isPicking = false

    var body: some View {
        HStack(alignment: .center, spacing: NudgyTheme.Metric.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.label)
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurface)

                if let supporting = supportingText {
                    Text(supporting)
                        .font(NudgyTheme.Typeface.labelMedium())
                        .foregroundStyle(
                            slot.provenance.isClinicalFact
                                ? NudgyTheme.Palette.primary
                                : NudgyTheme.Palette.onSurfaceMuted
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)

            // Accepting Nudgy's offer is one tap, but always an explicit act — a suggestion never
            // becomes the scheduled time on its own.
            if slot.timeOfDay == nil, let suggestion = slot.suggestion {
                Button {
                    slot.timeOfDay = suggestion.clockTime
                    slot.provenance = .patternNoticed(basis: "you picked this")
                } label: {
                    Text(suggestion.formatted)
                        .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(NudgyTheme.Palette.onTertiaryContainer)
                        .padding(.horizontal, NudgyTheme.Metric.sm)
                        .padding(.vertical, 7)
                        .background(NudgyTheme.Palette.tertiaryContainer, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Button {
                isPicking = true
            } label: {
                Text(slot.timeOfDay.map(ProposalCard.format) ?? "Set")
                    .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(NudgyTheme.Palette.onSurface)
                    .padding(.horizontal, NudgyTheme.Metric.sm)
                    .padding(.vertical, 7)
                    .background(NudgyTheme.Palette.surfaceContainer, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $isPicking) {
            TimePickerSheet(slot: $slot).presentationDetents([.height(360)])
        }
    }

    private var supportingText: String? {
        switch slot.provenance {
        case .fromYourRecord(let citation):
            return "Your chart says: \(citation.verbatimText)"
        case .needsReview:
            return suppressSupportingText ? nil : "Your chart doesn't say when."
        case .convenienceSuggestion:
            return suppressSupportingText ? nil : "My idea, not from your chart."
        case .patternNoticed(let basis):
            return "Set by you — \(basis)"
        }
    }
}

private struct TimePickerSheet: View {
    @Binding var slot: ProposedSlot
    @Environment(\.dismiss) private var dismiss
    @State private var picked = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: NudgyTheme.Metric.md) {
                DatePicker("", selection: $picked, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()

                Text("This one's your call — your chart didn't say when.")
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .background(NudgyTheme.Palette.background)
            .navigationTitle(slot.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        slot.timeOfDay = Calendar.current.dateComponents(
                            [.hour, .minute], from: picked
                        )
                        slot.provenance = .patternNoticed(basis: "you picked this")
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            let calendar = Calendar.current
            if let existing = slot.timeOfDay, let hour = existing.hour, let minute = existing.minute,
               let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) {
                picked = date
            } else if let suggested = slot.suggestion?.clockTime,
                      let hour = suggested.hour, let minute = suggested.minute,
                      let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) {
                picked = date
            } else if let fallback = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) {
                picked = fallback
            }
        }
    }
}
