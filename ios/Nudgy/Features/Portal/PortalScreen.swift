import SwiftUI

/// The Portal tab — where health records come from.
///
/// The mockup this is based on showed MyChart and Apple Health as live, syncing connections. This
/// version shows what is actually true: sample records, loaded locally, with the real connectors
/// marked as not yet built. Overstating a connection here would undercut the one thing the app is
/// asking to be trusted about.
struct PortalScreen: View {
    @EnvironmentObject private var session: NudgySession
    @State private var showStatus = false

    var body: some View {
        VStack(spacing: 0) {
            NudgyHeader { showStatus = true }

            ScrollView {
                VStack(alignment: .leading, spacing: NudgyTheme.Metric.md) {
                    greeting

                    ForEach(session.connectedSources) { source in
                        SourceCard(source: source)
                    }

                    addPlaceholder
                    privacyNote
                    scopeNote
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

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.greetingName.map { "Hello, \($0)" } ?? "Your records")
                .font(NudgyTheme.Typeface.headlineMedium())
                .foregroundStyle(NudgyTheme.Palette.onSurface)
            Text("Everything here lives on this phone. Nothing is uploaded.")
                .font(NudgyTheme.Typeface.bodyMedium())
                .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, NudgyTheme.Metric.xs)
    }

    private var addPlaceholder: some View {
        VStack(spacing: NudgyTheme.Metric.xs) {
            Image(systemName: "plus.circle")
                .font(.system(size: 22))
                .foregroundStyle(NudgyTheme.Palette.outline)
            Text("Connect a provider")
                .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
            Text("Sign-in through MyChart is coming — it isn't built yet.")
                .font(NudgyTheme.Typeface.labelMedium())
                .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(NudgyTheme.Metric.lg)
        .background(
            RoundedRectangle(cornerRadius: NudgyTheme.Metric.radiusLarge)
                .stroke(
                    NudgyTheme.Palette.outlineVariant,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
    }

    private var privacyNote: some View {
        InfoTile(
            icon: "lock.shield",
            title: "Your records stay on this phone",
            message: "They're encrypted here with a key that never leaves this device — so they can't "
                + "be read anywhere else, even from a backup.",
            tint: NudgyTheme.Palette.primary,
            background: NudgyTheme.Palette.secondaryContainer.opacity(0.4)
        )
    }

    private var scopeNote: some View {
        InfoTile(
            icon: "info.circle",
            title: "What I do and don't do",
            message: "I turn what's already written in your records into reminders, and I show you "
                + "where each one came from. I don't diagnose anything or tell you what to take.",
            tint: NudgyTheme.Palette.tertiary,
            background: NudgyTheme.Palette.tertiaryContainer.opacity(0.35)
        )
    }
}

/// One connected — or not yet connected — health source.
struct ConnectedSource: Identifiable, Hashable {
    enum Status: Hashable {
        case loaded(itemCount: Int)
        case notConnected
    }

    let id: String
    let name: String
    let detail: String
    let origin: DataOrigin
    let status: Status
}

private struct SourceCard: View {
    let source: ConnectedSource

    private var statusLabel: String {
        switch source.status {
        case .loaded(let count): return count == 1 ? "1 item" : "\(count) items"
        case .notConnected: return "Not connected"
        }
    }

    private var isLoaded: Bool {
        if case .loaded = source.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
            HStack(spacing: NudgyTheme.Metric.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: NudgyTheme.Metric.radius)
                        .fill(NudgyTheme.Palette.surfaceLow)
                        .frame(width: 32, height: 32)
                    Image(systemName: isLoaded ? "doc.text" : "link")
                        .font(.system(size: 14))
                        .foregroundStyle(NudgyTheme.Palette.primary)
                }

                Text(source.name)
                    .font(NudgyTheme.Typeface.titleLarge())
                    .foregroundStyle(NudgyTheme.Palette.onSurface)
                    .lineLimit(1)

                Spacer(minLength: NudgyTheme.Metric.xs)

                Text(statusLabel)
                    .font(NudgyTheme.Typeface.labelSmall())
                    .foregroundStyle(isLoaded
                                     ? NudgyTheme.Palette.onSecondaryContainer
                                     : NudgyTheme.Palette.onSurfaceMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        isLoaded
                            ? NudgyTheme.Palette.secondaryContainer
                            : NudgyTheme.Palette.surfaceContainer,
                        in: Capsule()
                    )
            }

            VStack(alignment: .leading, spacing: NudgyTheme.Metric.xs) {
                Text(source.detail)
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                // Provenance sits on the source itself, so synthetic records can never be mistaken
                // for a real chart pull. Nothing is loaded from an unconnected source, so it gets
                // no origin tag — claiming one would be describing data that isn't there.
                if isLoaded {
                    Text(source.origin.shortLabel)
                        .font(NudgyTheme.Typeface.labelSmall())
                        .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(NudgyTheme.Palette.surfaceLow, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 44)
        }
        .padding(NudgyTheme.Metric.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nudgyCard()
    }
}

struct InfoTile: View {
    let icon: String
    let title: String
    let message: String
    let tint: Color
    let background: Color

    var body: some View {
        HStack(alignment: .top, spacing: NudgyTheme.Metric.sm) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(NudgyTheme.Typeface.bodyMedium().weight(.semibold))
                    .foregroundStyle(NudgyTheme.Palette.onSurface)
                Text(message)
                    .font(NudgyTheme.Typeface.bodyMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NudgyTheme.Metric.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: NudgyTheme.Metric.radiusMedium))
    }
}
