import SwiftUI

/// The Reminders tab — "what do I need to do today?"
///
/// Proposals awaiting review and reminders already running share one chronological feed, with a
/// timeline rail down the left. Both are "things about today", and splitting them into separate
/// lists made the user hunt for whichever one they wanted.
struct RemindersScreen: View {
    @EnvironmentObject private var session: NudgySession
    @State private var showStatus = false
    @State private var filter: Filter = .scheduled
    @State private var isAddingReminder = false
    /// Slots lifted from the reminder a notification asked us to retime.
    @State private var notificationEditSlots: [ProposedSlot] = []
    @State private var previewing: ApprovedReminder?

    /// Two genuinely different things share this tab: a timetable, and a list of things you have
    /// on hand for when you need them. Mixing them made the timetable unreadable.
    enum Filter: String, CaseIterable, Identifiable {
        case scheduled
        case onDemand

        var id: String { rawValue }

        var title: String {
            switch self {
            case .scheduled: return "On a schedule"
            case .onDemand: return "When needed"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NudgyHeader(status: session.ledger.status) { showStatus = true }

            ScrollView {
                VStack(alignment: .leading, spacing: NudgyTheme.Metric.lg) {
                    title
                    filterPicker
                    if filter == .scheduled, !session.proposalsNeedingReview.isEmpty {
                        reviewBanner
                    }
                    if filter == .scheduled { feed } else { onDemandList }
                    addYourOwn
                    if !session.activeReminders.isEmpty { testNotification }
            if let result = session.testSendResult {
                HStack(alignment: .top, spacing: NudgyTheme.Metric.xs) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(NudgyTheme.Palette.tertiary)
                    Text(result)
                        .font(NudgyTheme.Typeface.bodyMedium())
                        .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(NudgyTheme.Metric.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    NudgyTheme.Palette.surfaceLow,
                    in: RoundedRectangle(cornerRadius: NudgyTheme.Metric.radiusMedium)
                )
                .onTapGesture { session.testSendResult = nil }
            }
                    endOfFeed
                }
                .padding(.horizontal, NudgyTheme.Metric.containerMargin)
                .padding(.top, NudgyTheme.Metric.md)
                .padding(.bottom, NudgyTheme.Metric.xl)
            }
        }
        .background(NudgyTheme.Palette.background.ignoresSafeArea())
        .sheet(isPresented: $showStatus) {
            PrivacySheet(status: session.status, provider: session.languageProvider, narrationError: session.lastNarrationError)
        }
        // "Change the time" on a notification opens the app; this is what it opens *to*. Without
        // it the action is a dead end, which is worse than not offering it.
        .onChange(of: session.pendingTimeEditReminderID) { _, id in
            guard let id,
                  let reminder = session.activeReminders.first(where: { $0.id == id })
            else { return }
            notificationEditSlots = reminder.times.enumerated().map { index, time in
                ProposedSlot(
                    id: "\(reminder.id)#\(index)",
                    timeOfDay: time,
                    provenance: .patternNoticed(basis: "you picked this"),
                    label: reminder.times.count == 1
                        ? "Daily reminder"
                        : "Reminder \(index + 1) of \(reminder.times.count)"
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { session.pendingTimeEditReminderID != nil },
                set: { if !$0 { session.pendingTimeEditReminderID = nil } }
            )
        ) {
            if let id = session.pendingTimeEditReminderID,
               let reminder = session.activeReminders.first(where: { $0.id == id }) {
                TimesSheet(title: reminder.title, slots: $notificationEditSlots)
                    .onDisappear {
                        let times = notificationEditSlots.compactMap(\.timeOfDay)
                        Task { await session.updateTimes(for: reminder, to: times) }
                    }
            }
        }
        .sheet(item: $previewing) { reminder in
            NotificationPreviewSheet(reminder: reminder) {
                Task { await session.demoFire(reminder) }
            }
        }
        .sheet(isPresented: $isAddingReminder) {
            AddReminderSheet { title, times in
                Task { await session.createUserReminder(title: title, times: times) }
            }
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TODAY'S SCHEDULE")
                .font(NudgyTheme.Typeface.labelMedium())
                .kerning(0.8)
                .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)
            Text("Reminders")
                .font(NudgyTheme.Typeface.displayLarge())
                .foregroundStyle(NudgyTheme.Palette.onSurface)
        }
    }

    private var filterPicker: some View {
        Picker("Show", selection: $filter) {
            ForEach(Filter.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
    }

    /// Medications the record says are taken only when needed. Deliberately timeless: giving one a
    /// daily slot would turn an as-needed prescription into a standing one.
    private var onDemandList: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.md) {
            if session.onDemandProposals.isEmpty {
                Text("Nothing in your records is listed as taken only when needed.")
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)
            } else {
                Text("Your records list these as taken only when you need them, so I don't set "
                     + "times for them.")
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(session.onDemandProposals) { proposal in
                    OnDemandRow(proposal: proposal)
                }
            }
        }
    }

    /// A quiet count rather than a wall of cards to clear. Review should feel like a short detour,
    /// not a gate in front of the app.
    private var reviewBanner: some View {
        HStack(spacing: NudgyTheme.Metric.sm) {
            Image(systemName: "tray.full")
                .font(.system(size: 15))
                .foregroundStyle(NudgyTheme.Palette.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.activeReminders.count) set up · \(session.proposalsNeedingReview.count) to look at")
                    .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                    .foregroundStyle(NudgyTheme.Palette.onSurface)
                Text("These are already running. A couple need your eye before I set them.")
                    .font(NudgyTheme.Typeface.labelMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(NudgyTheme.Metric.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            NudgyTheme.Palette.tertiaryContainer.opacity(0.45),
            in: RoundedRectangle(cornerRadius: NudgyTheme.Metric.radiusMedium)
        )
    }

    private var feed: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.lg) {
            ForEach(session.activeReminders) { reminder in
                TimelineRow(kind: reminder.kind) {
                    ActiveReminderCard(
                        reminder: reminder,
                        onCommitTimes: { times in
                            Task { await session.updateTimes(for: reminder, to: times) }
                        },
                        onStop: { Task { await session.stopReminding(reminder) } }
                    )
                }
            }

            ForEach(session.proposalsNeedingReview) { proposal in
                TimelineRow(kind: proposal.kind) {
                    ProposalCard(
                        proposal: proposal,
                        onApprove: { item in Task { await session.approve(item) } },
                        onEdit: { item in Task { await session.edit(item) } },
                        onSkip: { item in Task { await session.skip(item) } },
                        onChooseFrequency: { count, item in
                            Task { await session.applyFrequency(count, to: item) }
                        }
                    )
                }
            }
        }
        .background(alignment: .topLeading) {
            // A single unbroken rail, rather than a segment per row — segments leave gaps at the
            // card boundaries and the line stops reading as one thread.
            HStack(spacing: 0) {
                Rectangle()
                    .fill(NudgyTheme.Palette.outlineVariant.opacity(0.35))
                    .frame(width: 2)
                    .padding(.vertical, 24)
                Spacer(minLength: 0)
            }
            .padding(.leading, 23)
        }
    }

    /// Anything that is not in a chart. Hydration, a supplement, a stretch someone was told about
    /// verbally — the record cannot cover everything, and Nudgy will not invent what is missing,
    /// so the person supplies it and is recorded as the source.
    private var addYourOwn: some View {
        Button {
            isAddingReminder = true
        } label: {
            HStack(spacing: NudgyTheme.Metric.xs) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 16))
                Text("Add your own reminder")
                    .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(NudgyTheme.Palette.primary)
            .padding(NudgyTheme.Metric.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: NudgyTheme.Metric.radiusMedium)
                    .stroke(
                        NudgyTheme.Palette.outlineVariant,
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// Fires a real local notification about ten seconds out.
    ///
    /// Reminders are scheduled for real clock times, so without this the only way to see one is to
    /// wait until morning — which is no way to check that the loop works, and no way to show it to
    /// anyone. It still takes an existing approved reminder: even the test path cannot conjure an
    /// alert for something the user never agreed to.
    private var testNotification: some View {
        Button {
            previewing = session.activeReminders.first
            if previewing == nil {
                session.testSendResult = "Approve a reminder first — there's nothing to send yet."
            }
        } label: {
            HStack(spacing: NudgyTheme.Metric.xs) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 14))
                Text("Send one now to test")
                    .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                Spacer(minLength: 0)
                Text("~10s")
                    .font(NudgyTheme.Typeface.labelSmall())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)
            }
            .foregroundStyle(NudgyTheme.Palette.tertiary)
            .padding(NudgyTheme.Metric.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                NudgyTheme.Palette.tertiaryContainer.opacity(0.35),
                in: RoundedRectangle(cornerRadius: NudgyTheme.Metric.radiusMedium)
            )
        }
        .buttonStyle(.plain)
    }

    private var endOfFeed: some View {
        VStack(spacing: NudgyTheme.Metric.xs) {
            Image(systemName: "calendar")
                .font(.system(size: 22))
                .foregroundStyle(NudgyTheme.Palette.outlineVariant)
            Text(session.activeReminders.isEmpty && session.proposalsNeedingReview.isEmpty
                 ? "Nothing for today. I'll let you know if that changes."
                 : "That's everything for today.")
                .font(NudgyTheme.Typeface.bodyMedium())
                .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, NudgyTheme.Metric.lg)
    }

}

/// A card with the timeline rail and category badge to its left.
private struct TimelineRow<Content: View>: View {
    let kind: ReminderKind
    @ViewBuilder var content: Content

    /// Category, not status, drives the badge colour — matching the mockup, where medication is a
    /// filled sage disc and movement is a lighter one. Status already has the chip.
    private var fill: Color {
        switch kind {
        case .medication: return NudgyTheme.Palette.primary
        case .therapy: return NudgyTheme.Palette.secondaryContainer
        case .nutrition: return NudgyTheme.Palette.tertiaryContainer
        }
    }

    private var symbol: String {
        switch kind {
        case .medication: return "pills.fill"
        case .therapy: return "figure.cooldown"
        case .nutrition: return "fork.knife"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: NudgyTheme.Metric.md) {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: 48, height: 48)
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(kind == .medication
                                     ? NudgyTheme.Palette.onPrimary
                                     : NudgyTheme.Palette.primary)
            }

            content
        }
    }
}

/// A reminder that is already running. Fewer decisions than a proposal — just the two escape
/// hatches the notification also offers.
private struct ActiveReminderCard: View {
    let reminder: ApprovedReminder
    var onCommitTimes: ([DateComponents]) -> Void
    var onStop: () -> Void

    @State private var showSources = false
    @State private var isPickingTimes = false
    @State private var editableSlots: [ProposedSlot] = []

    /// The sheet edits `ProposedSlot`s, so a running reminder's times are lifted into that shape
    /// and written back on dismiss. Keeps one time editor in the app rather than two.
    private func beginEditing() {
        editableSlots = reminder.times.enumerated().map { index, time in
            ProposedSlot(
                id: "\(reminder.id)#\(index)",
                timeOfDay: time,
                provenance: .patternNoticed(basis: "you picked this"),
                label: reminder.times.count == 1
                    ? "Daily reminder"
                    : "Reminder \(index + 1) of \(reminder.times.count)"
            )
        }
        isPickingTimes = true
    }

    private var timeText: String {
        let times = reminder.times.map(ProposalCard.format)
        return times.isEmpty ? "Any time" : times.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.md) {
            HStack(alignment: .top) {
                Button {
                    beginEditing()
                } label: {
                    HStack(spacing: NudgyTheme.Metric.xs) {
                        Text(reminder.times.first.map(ProposalCard.format) ?? "No time")
                            .font(NudgyTheme.Typeface.displayLarge())
                            .foregroundStyle(NudgyTheme.Palette.primary)
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    }
                }
                .buttonStyle(.plain)
                .disabled(reminder.times.isEmpty)
                .accessibilityLabel("Change the time")
                Spacer(minLength: NudgyTheme.Metric.xs)
                StatusChip(state: reminder.times.isEmpty ? .onlyWhenNeeded : .active)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(NudgyTheme.Typeface.titleLarge())
                    .foregroundStyle(NudgyTheme.Palette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)

                Text(reminder.sourceLabel)
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
            }

            if reminder.times.count > 1 {
                Text(timeText)
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSources.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showSources ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(showSources ? "Hide where this came from" : "Where did this come from?")
                }
                .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                .foregroundStyle(NudgyTheme.Palette.primary)
            }
            .buttonStyle(.plain)

            if showSources {
                VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
                    ForEach(reminder.sourceFacts) { fact in
                        VerbatimQuote(
                            label: fact.label,
                            text: fact.verbatim,
                            citation: fact.citation
                        )
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: NudgyTheme.Metric.xs) {
                Button("Change time") { beginEditing() }
                    .buttonStyle(OutlineButtonStyle())
                    .disabled(reminder.times.isEmpty)
                Button("Stop reminding", action: onStop)
                    .buttonStyle(OutlineButtonStyle(tint: NudgyTheme.Palette.onSurfaceVariant))
                Spacer(minLength: 0)
            }
        }
        .padding(NudgyTheme.Metric.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nudgyCard()
        .sheet(isPresented: $isPickingTimes, onDismiss: {
            onCommitTimes(editableSlots.compactMap(\.timeOfDay))
        }) {
            TimesSheet(title: reminder.title, slots: $editableSlots)
        }
    }
}


/// A medication taken only when needed. No time, no approval — just what the record says.
private struct OnDemandRow: View {
    let proposal: ReminderProposal
    @State private var showSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
            HStack(alignment: .top) {
                Text(proposal.title)
                    .font(NudgyTheme.Typeface.titleLarge())
                    .foregroundStyle(NudgyTheme.Palette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NudgyTheme.Metric.xs)
                StatusChip(state: .onlyWhenNeeded)
            }

            Text(proposal.sourceLabel)
                .font(NudgyTheme.Typeface.bodyMedium())
                .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSources.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showSources ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(showSources ? "Hide where this came from" : "Where did this come from?")
                }
                .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                .foregroundStyle(NudgyTheme.Palette.primary)
            }
            .buttonStyle(.plain)

            if showSources {
                VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
                    ForEach(proposal.sourceFacts) { fact in
                        VerbatimQuote(label: fact.label, text: fact.verbatim, citation: fact.citation)
                    }
                }
            }
        }
        .padding(NudgyTheme.Metric.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nudgyCard()
    }
}


/// Creating a reminder that is not in any record.
private struct AddReminderSheet: View {
    var onCreate: (String, [DateComponents]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var timesPerDay = 1
    @State private var firstTime = Calendar.current.date(
        bySettingHour: 9, minute: 0, second: 0, of: Date()
    ) ?? Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("What should I remind you about?") {
                    TextField("For example, drink water", text: $title)
                }
                Section("How often") {
                    Picker("Times a day", selection: $timesPerDay) {
                        ForEach(1...4, id: \.self) { count in
                            Text(count == 1 ? "Once a day" : "\(count) times a day").tag(count)
                        }
                    }
                    DatePicker("First one at", selection: $firstTime,
                               displayedComponents: .hourAndMinute)
                }
                Section {
                    Text("This one is yours, not from your records — so it will say you added it.")
                        .font(NudgyTheme.Typeface.bodyMedium())
                        .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                }
            }
            .navigationTitle("Add a reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onCreate(title, spreadTimes())
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// Spreads the chosen count evenly through the waking day from the first time.
    private func spreadTimes() -> [DateComponents] {
        let calendar = Calendar.current
        let start = calendar.dateComponents([.hour, .minute], from: firstTime)
        guard let hour = start.hour, let minute = start.minute else { return [] }
        guard timesPerDay > 1 else { return [DateComponents(hour: hour, minute: minute)] }

        let startMinutes = hour * 60 + minute
        let span = min(14 * 60, (22 * 60) - startMinutes)
        let step = span / max(timesPerDay - 1, 1)
        return (0..<timesPerDay).map { index in
            let total = min(startMinutes + step * index, 22 * 60)
            return DateComponents(hour: total / 60, minute: total % 60)
        }
    }
}


/// Shows exactly what the notification will say, before sending one.
///
/// Two reasons this exists rather than just firing. A reminder fires at a real clock time, so
/// during a demo there is otherwise nothing to look at; and the interesting part of this design is
/// the *difference* between what a stranger sees and what the owner sees, which a single banner
/// cannot show.
private struct NotificationPreviewSheet: View {
    let reminder: ApprovedReminder
    var onSend: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var timeText: String {
        reminder.times.first.flatMap(NotificationScheduler.formatted) ?? "Any time"
    }

    private var instruction: String? {
        reminder.sourceFacts.first { $0.label.lowercased().contains("instruction") }?.verbatim
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NudgyTheme.Metric.lg) {
                    section("WHEN YOUR PHONE IS LOCKED") {
                        banner(
                            title: "Nudgy",
                            subtitle: nil,
                            body: "Nudgy has a message for you"
                        )
                        Text("A stranger glancing at your phone learns only that you use Nudgy.")
                            .font(NudgyTheme.Typeface.bodyMedium())
                            .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    section("WHEN FACE ID RECOGNISES YOU") {
                        banner(
                            title: reminder.title,
                            subtitle: "\(timeText) · \(reminder.sourceLabel)",
                            body: instruction.map { "Your record says: \($0)" }
                                ?? NotificationScheduler.discreetBody(for: reminder.kind)
                        )
                        actionsRow
                        Text("This only stays hidden while Show Previews is set to When Unlocked, "
                             + "which is the default. Setting it to Always puts the medication name "
                             + "on your lock screen.")
                            .font(NudgyTheme.Typeface.labelMedium())
                            .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        onSend()
                        dismiss()
                    } label: {
                        Text("Send one now (about 10 seconds)")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(NudgyTheme.Metric.containerMargin)
            }
            .background(NudgyTheme.Palette.background)
            .navigationTitle("Notification preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
            Text(title)
                .font(NudgyTheme.Typeface.labelSmall())
                .kerning(0.7)
                .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)
            content()
        }
    }

    /// Approximates the iOS banner so the copy can be judged in something close to its real shape.
    private func banner(title: String, subtitle: String?, body: String) -> some View {
        HStack(alignment: .top, spacing: NudgyTheme.Metric.sm) {
            RoundedRectangle(cornerRadius: 9)
                .fill(NudgyTheme.Palette.secondaryContainer)
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "leaf")
                        .font(.system(size: 16))
                        .foregroundStyle(NudgyTheme.Palette.primary)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NudgyTheme.Typeface.bodyMedium().weight(.semibold))
                    .foregroundStyle(NudgyTheme.Palette.onSurface)
                if let subtitle {
                    Text(subtitle)
                        .font(NudgyTheme.Typeface.bodyMedium())
                        .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                }
                Text(body)
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(NudgyTheme.Metric.sm)
        .background(NudgyTheme.Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }

    private var actionsRow: some View {
        VStack(spacing: 1) {
            ForEach(["Taken", "Remind me later", "Stop reminding"], id: \.self) { label in
                Text(label)
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(label == "Stop reminding"
                                     ? NudgyTheme.Palette.error
                                     : NudgyTheme.Palette.onSurface)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(NudgyTheme.Palette.surface)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(NudgyTheme.Palette.hairline, lineWidth: 1)
        }
    }
}
