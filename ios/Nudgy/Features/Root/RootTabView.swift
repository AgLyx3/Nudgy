import SwiftUI

/// Three tabs, matching the Serene design: Portal, Reminders, Chat.
///
/// Reminders is the default because it answers the question people actually open the app with —
/// "what do I need to do?" — and because a wall of review cards in a chat log was the single
/// worst thing about the previous single-timeline design.
struct RootTabView: View {
    @EnvironmentObject private var session: NudgySession

    var body: some View {
        // Reminders is first, and therefore the landing tab: it answers the question people
        // actually open the app with. No selection binding — on iOS 26 the binding was being
        // ignored on first render, and tab order is the reliable way to express a default.
        TabView {
            RemindersScreen()
                .tabItem { Label("Reminders", systemImage: "bell") }

            PortalScreen()
                .tabItem { Label("Portal", systemImage: "point.3.connected.trianglepath.dotted") }

            ConversationScreen()
                .tabItem { Label("Chat", systemImage: "bubble.left") }
        }
        .tint(NudgyTheme.Palette.primary)
    }
}

/// The header that sits above every tab. Names the app and keeps the privacy state one tap away.
struct NudgyHeader: View {
    var status: AdherenceStatus = .current
    var onOpenStatus: () -> Void

    /// Green / amber / red, as a dashboard light rather than a score.
    ///
    /// Red here means "several reminders have gone unanswered" — never "you missed three doses".
    /// We only know what was tapped and what was silence, and silence is ambiguous. It is a prompt
    /// to look, not a verdict.
    ///
    /// Deliberately a small dot rather than a card: card-level concerns stay amber blocks, so the
    /// two uses of colour never sit side by side competing.
    private var statusTint: Color {
        switch status {
        case .current: return NudgyTheme.Palette.primary
        case .attention: return NudgyTheme.Palette.concern
        case .needsLook: return NudgyTheme.Palette.error
        }
    }

    var body: some View {
        HStack(spacing: NudgyTheme.Metric.sm) {
            ZStack {
                Circle()
                    .fill(NudgyTheme.Palette.secondaryContainer)
                    .frame(width: 34, height: 34)
                Image(systemName: "leaf")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NudgyTheme.Palette.primary)
            }

            Text("Nudgy")
                .font(NudgyTheme.Typeface.headlineSmall())
                .foregroundStyle(NudgyTheme.Palette.primary)

            Spacer()

            Button(action: onOpenStatus) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 9, height: 9)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 17))
                        .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(status.summary). Privacy and on-device status.")
        }
        .padding(.horizontal, NudgyTheme.Metric.containerMargin)
        .padding(.vertical, NudgyTheme.Metric.sm)
        .background(NudgyTheme.Palette.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(NudgyTheme.Palette.hairline)
                .frame(height: 1)
        }
    }
}
