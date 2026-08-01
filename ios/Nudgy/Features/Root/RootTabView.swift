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
    var onOpenStatus: () -> Void

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
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 17))
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Privacy and on-device status")
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
