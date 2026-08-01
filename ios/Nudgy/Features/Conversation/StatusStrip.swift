import SwiftUI

/// The always-visible privacy header.
///
/// The design doc asks to "keep privacy status visible". The important discipline here is that
/// every value shown is read from live state — the microphone indicator reflects the actual
/// recognizer, and the model indicator reflects which language model is actually loaded. A
/// hardcoded "On device" badge would be exactly the kind of reassuring lie this product exists
/// to avoid.
struct ConversationHeader: View {
    let status: SessionStatus
    var onOpenPrivacy: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Private conversation")
                    .font(NudgyTheme.Typeface.labelSmall())
                    .kerning(0.7)
                    .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)
                Text("Nudgy")
                    .font(NudgyTheme.Typeface.headlineMedium())
                    .foregroundStyle(NudgyTheme.Palette.onSurface)
            }

            Spacer()

            Button(action: onOpenPrivacy) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.modelIsOnDevice
                              ? NudgyTheme.Palette.primary
                              : NudgyTheme.Palette.concern)
                        .frame(width: 7, height: 7)
                    Text(status.modelIsOnDevice ? "On device" : "Check status")
                        .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                }
                .foregroundStyle(NudgyTheme.Palette.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(NudgyTheme.Palette.secondaryContainer, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Privacy and on-device status")
        }
    }
}

/// Storage / model / network — the three questions someone actually has about a health app:
/// where does my data sit, who is doing the thinking, and does any of it go anywhere.
///
/// Voice capture used to occupy the first cell. It was cut from v1, so the strip now spends that
/// space on network egress instead, which is the more load-bearing claim.
struct StatusStrip: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 0) {
            cell(label: "Storage", value: status.storageDescription, tint: NudgyTheme.Palette.onSurface)
            divider
            cell(label: "Model", value: status.modelDescription, tint: NudgyTheme.Palette.onSurface)
            divider
            cell(
                label: "Network",
                value: status.networkEgressDescription,
                tint: NudgyTheme.Palette.primary
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(NudgyTheme.Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(NudgyTheme.Palette.hairline, lineWidth: 1)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(NudgyTheme.Palette.hairline)
            .frame(width: 1, height: 26)
    }

    private func cell(label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(label.uppercased())
                .font(NudgyTheme.Typeface.labelSmall())
                .kerning(0.5)
                .foregroundStyle(NudgyTheme.Palette.onSurfaceMuted)

            Text(value)
                .font(NudgyTheme.Typeface.bodyMedium().weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
