import SwiftUI

/// The reviewable reminder card — the centerpiece of the trust loop.
///
/// Everything clinical on this card is quoted from the record and attributed. The only thing
/// Nudgy authors is the *timing suggestion*, and that is visually and verbally separated from
/// the chart facts so the two can never be confused.
struct ProposalCard: View {
    let proposal: ReminderProposal
    var onApprove: (ReminderProposal) -> Void
    var onEdit: (ReminderProposal) -> Void
    var onSkip: (ReminderProposal) -> Void

    @State private var showSources = false
    @State private var workingSlots: [ProposedSlot]
    @State private var didAdjustTimes = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.stackGap) {
            header

            if let subtitle = proposal.subtitle {
                Text(subtitle)
                    .font(NudgyTheme.Typeface.ui())
                    .foregroundStyle(NudgyTheme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let declined = proposal.schedulingDeclinedReason {
                declinedNotice(declined)
            } else if !workingSlots.isEmpty {
                slotSection
            }

            ForEach(proposal.flags) { flag in
                FlagRow(flag: flag)
            }

            sourceDisclosure
            actionRow
        }
        .padding(NudgyTheme.Metric.gutter)
        .background(NudgyTheme.Palette.surface, in: RoundedRectangle(cornerRadius: NudgyTheme.Metric.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: NudgyTheme.Metric.cardRadius)
                .stroke(NudgyTheme.Palette.hairline, lineWidth: 1)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProvenanceBadge(provenance: proposal.primaryProvenance)
                Spacer(minLength: 0)
                Label(
                    proposal.kind == .medication ? "Medication" : "Exercise",
                    systemImage: proposal.kind == .medication ? "pills" : "figure.cooldown"
                )
                .font(NudgyTheme.Typeface.micro())
                .foregroundStyle(NudgyTheme.Palette.inkTertiary)
            }

            Text(proposal.title)
                .font(NudgyTheme.Typeface.cardTitle())
                .foregroundStyle(NudgyTheme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Scheduling

    /// Shown when the engine deliberately refused to propose a recurring schedule — most often
    /// an as-needed medication. Declining is the correct clinical behavior, so it is presented as
    /// a considered decision rather than a failure.
    private func declinedNotice(_ reason: ReviewReason) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 13))
                .foregroundStyle(NudgyTheme.Palette.inkSecondary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("I am not setting a repeating reminder for this.")
                    .font(NudgyTheme.Typeface.label())
                    .foregroundStyle(NudgyTheme.Palette.ink)
                Text(reason.plainLanguage)
                    .font(NudgyTheme.Typeface.ui())
                    .foregroundStyle(NudgyTheme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NudgyTheme.Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: 12))
    }

    private var slotSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Proposed times")
                .font(NudgyTheme.Typeface.micro())
                .kerning(0.5)
                .foregroundStyle(NudgyTheme.Palette.inkTertiary)

            ForEach($workingSlots) { $slot in
                SlotRow(slot: $slot, onChange: { didAdjustTimes = true })
            }
        }
    }

    // MARK: - Sources

    private var sourceDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSources.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showSources ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(showSources
                         ? "Hide where this came from"
                         : "Where did this come from?")
                }
                .font(NudgyTheme.Typeface.label())
                .foregroundStyle(NudgyTheme.Palette.trust)
            }
            .buttonStyle(.plain)

            if showSources {
                VStack(alignment: .leading, spacing: 8) {
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

    // MARK: - Actions

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button(approveTitle) {
                var approved = proposal
                approved.slots = workingSlots
                onApprove(approved)
            }
            .buttonStyle(CalmButtonStyle(emphasis: .primary))
            .disabled(!canApprove)
            .opacity(canApprove ? 1 : 0.45)

            Button("Edit") { onEdit(proposal) }
                .buttonStyle(CalmButtonStyle(emphasis: .secondary))

            Button("Skip") { onSkip(proposal) }
                .buttonStyle(CalmButtonStyle(emphasis: .quiet))

            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    private var approveTitle: String {
        proposal.schedulingDeclinedReason != nil ? "Keep in my list" : "Approve"
    }

    /// A reminder with an unset time cannot be scheduled — there is nothing to schedule it *at*.
    /// The user must supply the time the chart didn't.
    private var canApprove: Bool {
        if proposal.schedulingDeclinedReason != nil { return true }
        return !workingSlots.contains { $0.timeOfDay == nil }
    }
}

/// One proposed time. Renders very differently depending on where the time came from.
private struct SlotRow: View {
    @Binding var slot: ProposedSlot
    var onChange: () -> Void

    @State private var isPicking = false

    private var timeIsFromRecord: Bool { slot.provenance.isClinicalFact }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: slot.timeOfDay == nil ? "questionmark.circle" : "bell")
                .font(.system(size: 14))
                .foregroundStyle(
                    slot.timeOfDay == nil
                        ? NudgyTheme.Palette.concern
                        : NudgyTheme.Palette.trust
                )
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(slot.label)
                    .font(NudgyTheme.Typeface.ui())
                    .foregroundStyle(NudgyTheme.Palette.ink)

                Text(supportingText)
                    .font(NudgyTheme.Typeface.micro())
                    .foregroundStyle(
                        timeIsFromRecord
                            ? NudgyTheme.Palette.trust
                            : NudgyTheme.Palette.inkTertiary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                isPicking = true
            } label: {
                Text(slot.timeOfDay == nil ? "Set time" : slot.formattedTime)
                    .font(NudgyTheme.Typeface.label())
                    .foregroundStyle(
                        slot.timeOfDay == nil
                            ? NudgyTheme.Palette.concern
                            : NudgyTheme.Palette.ink
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(NudgyTheme.Palette.surfaceSunken, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $isPicking) {
            TimePickerSheet(slot: $slot, onChange: onChange)
                .presentationDetents([.height(340)])
        }
    }

    /// The sentence that keeps a Nudgy suggestion from being mistaken for a clinical instruction.
    private var supportingText: String {
        switch slot.provenance {
        case .fromYourRecord(let citation):
            return "Your record says: \(citation.verbatimText)"
        case .needsReview(let reason):
            return reason.plainLanguage
        case .convenienceSuggestion(let basis):
            return "My suggestion, not from your chart — \(basis)"
        case .patternNoticed(let basis):
            return "Pattern I noticed — \(basis)"
        }
    }
}

private struct TimePickerSheet: View {
    @Binding var slot: ProposedSlot
    var onChange: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var pickedDate = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: NudgyTheme.Metric.stackGap) {
                DatePicker(
                    "Reminder time",
                    selection: $pickedDate,
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.wheel)
                .labelsHidden()

                Text("You are choosing this time. Your record did not specify one.")
                    .font(NudgyTheme.Typeface.ui())
                    .foregroundStyle(NudgyTheme.Palette.inkSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer()
            }
            .padding(.top)
            .background(NudgyTheme.Palette.canvas)
            .navigationTitle(slot.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        let components = Calendar.current.dateComponents(
                            [.hour, .minute], from: pickedDate
                        )
                        slot.timeOfDay = components
                        // The user chose it, so it is no longer an unreviewed gap — but it is
                        // still explicitly not a clinical instruction from the chart.
                        slot.provenance = .patternNoticed(basis: "you chose this time")
                        onChange()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            if let existing = slot.timeOfDay,
               let hour = existing.hour, let minute = existing.minute,
               let date = Calendar.current.date(
                bySettingHour: hour, minute: minute, second: 0, of: Date()
               ) {
                pickedDate = date
            } else if let defaultDate = Calendar.current.date(
                bySettingHour: 8, minute: 0, second: 0, of: Date()
            ) {
                pickedDate = defaultDate
            }
        }
    }
}
