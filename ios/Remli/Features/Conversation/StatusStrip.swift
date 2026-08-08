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
                    .font(RemliTheme.Typeface.labelSmall())
                    .kerning(0.7)
                    .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)
                Text("Remli")
                    .font(RemliTheme.Typeface.headlineMedium())
                    .foregroundStyle(RemliTheme.Palette.onSurface)
            }

            Spacer()

            Button(action: onOpenPrivacy) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(status.modelIsOnDevice
                              ? RemliTheme.Palette.primary
                              : RemliTheme.Palette.concern)
                        .frame(width: 7, height: 7)
                    Text(status.modelIsOnDevice ? "On device" : "Check status")
                        .font(RemliTheme.Typeface.bodyMedium().weight(.medium))
                }
                .foregroundStyle(RemliTheme.Palette.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RemliTheme.Palette.secondaryContainer, in: Capsule())
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
            cell(label: "Storage", value: status.storageDescription, tint: RemliTheme.Palette.onSurface)
            divider
            cell(label: "Model", value: status.modelDescription, tint: RemliTheme.Palette.onSurface)
            divider
            cell(
                label: "Network",
                value: status.networkEgressDescription,
                tint: RemliTheme.Palette.primary
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(RemliTheme.Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(RemliTheme.Palette.hairline, lineWidth: 1)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(RemliTheme.Palette.hairline)
            .frame(width: 1, height: 26)
    }

    private func cell(label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(label.uppercased())
                .font(RemliTheme.Typeface.labelSmall())
                .kerning(0.5)
                .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)

            Text(value)
                .font(RemliTheme.Typeface.bodyMedium().weight(.medium))
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
