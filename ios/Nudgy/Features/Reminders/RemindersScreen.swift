import SwiftUI

/// The Reminders tab — "what do I need to do today?"
///
/// Proposals awaiting review and reminders already running share one chronological feed, with a
/// timeline rail down the left. Both are "things about today", and splitting them into separate
/// lists made the user hunt for whichever one they wanted.
struct RemindersScreen: View {
    @EnvironmentObject private var session: NudgySession
    @State private var showStatus = false

    var body: some View {
        VStack(spacing: 0) {
            NudgyHeader { showStatus = true }

            ScrollView {
                VStack(alignment: .leading, spacing: NudgyTheme.Metric.lg) {
                    title
                    if !session.openProposals.isEmpty { reviewBanner }
                    feed
                    endOfFeed
                }
                .padding(.horizontal, NudgyTheme.Metric.containerMargin)
                .padding(.top, NudgyTheme.Metric.md)
                .padding(.bottom, NudgyTheme.Metric.xl)
            }
        }
        .background(NudgyTheme.Palette.background.ignoresSafeArea())
        .sheet(isPresented: $showStatus) {
            PrivacySheet(status: session.status, provider: session.languageProvider)
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

    /// A quiet count rather than a wall of cards to clear. Review should feel like a short detour,
    /// not a gate in front of the app.
    private var reviewBanner: some View {
        HStack(spacing: NudgyTheme.Metric.sm) {
            Image(systemName: "tray.full")
                .font(.system(size: 15))
                .foregroundStyle(NudgyTheme.Palette.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.activeReminders.count) set up · \(session.openProposals.count) to look at")
                    .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                    .foregroundStyle(NudgyTheme.Palette.onSurface)
                Text("I found these in your records. Nothing gets scheduled until you say so.")
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
                        onChangeTime: { session.requestTimeChange(for: reminder) },
                        onStop: { Task { await session.stopReminding(reminder) } }
                    )
                }
            }

            ForEach(session.openProposals) { proposal in
                TimelineRow(kind: proposal.kind) {
                    ProposalCard(
                        proposal: proposal,
                        onApprove: { item in Task { await session.approve(item) } },
                        onEdit: { item in Task { await session.edit(item) } },
                        onSkip: { item in Task { await session.skip(item) } }
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

    private var endOfFeed: some View {
        VStack(spacing: NudgyTheme.Metric.xs) {
            Image(systemName: "calendar")
                .font(.system(size: 22))
                .foregroundStyle(NudgyTheme.Palette.outlineVariant)
            Text(session.activeReminders.isEmpty && session.openProposals.isEmpty
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
        }
    }

    private var symbol: String {
        switch kind {
        case .medication: return "pills.fill"
        case .therapy: return "figure.cooldown"
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
                                     : NudgyTheme.Palette.onSecondaryContainer)
            }

            content
        }
    }
}

/// A reminder that is already running. Fewer decisions than a proposal — just the two escape
/// hatches the notification also offers.
private struct ActiveReminderCard: View {
    let reminder: ApprovedReminder
    var onChangeTime: () -> Void
    var onStop: () -> Void

    @State private var showSources = false

    private var timeText: String {
        let times = reminder.times.map(ProposalCard.format)
        return times.isEmpty ? "Any time" : times.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.md) {
            HStack(alignment: .top) {
                Text(reminder.times.first.map(ProposalCard.format) ?? "Any time")
                    .font(NudgyTheme.Typeface.clock())
                    .foregroundStyle(NudgyTheme.Palette.primary)
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
                Button("Change time", action: onChangeTime)
                    .buttonStyle(OutlineButtonStyle())
                Button("Stop reminding", action: onStop)
                    .buttonStyle(OutlineButtonStyle(tint: NudgyTheme.Palette.onSurfaceVariant))
                Spacer(minLength: 0)
            }
        }
        .padding(NudgyTheme.Metric.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nudgyCard()
    }
}
