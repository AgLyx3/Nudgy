import SwiftUI

/// Remli's visual language, adopted from the "Clinical Zen" design system in
/// `stitch_serene_health_assistant/serene_health/DESIGN.md`.
///
/// Two deliberate departures from that spec, both for safety rather than taste:
///
/// 1. **Concerns are amber, not red.** The spec reserves `error` (#ba1a1a) for alerts, and the
///    mockup used it for a medication callout. Two clinics recording different instructions is
///    something to raise with a care team, not an emergency, and alarm-red overstates it every
///    time it appears. Red stays for genuine system failures only.
/// 2. **A monospace slot exists** even though the spec is Inter throughout. Verbatim chart text is
///    quoted, and a quotation has to look like one — that is a safety affordance, not decoration.
///
/// Inter is substituted with the system font at the spec'd sizes and weights. On iOS, SF matches
/// Inter's proportions closely and avoids bundling a webfont; the metrics below are taken directly
/// from the design system's typography scale.
enum RemliTheme {

    // MARK: - Color

    enum Palette {
        // Surfaces
        static let background = Color(hex: 0xF8FAFB)
        static let surface = Color(hex: 0xFFFFFF)
        static let surfaceLow = Color(hex: 0xF2F4F5)
        static let surfaceContainer = Color(hex: 0xECEEEF)
        static let surfaceHigh = Color(hex: 0xE6E8E9)

        // Text
        static let onSurface = Color(hex: 0x191C1D)
        static let onSurfaceVariant = Color(hex: 0x414942)
        static let onSurfaceMuted = Color(hex: 0x717971)

        // Primary — sage. Brand, primary actions, and record-sourced truth.
        static let primary = Color(hex: 0x316342)
        static let onPrimary = Color(hex: 0xFFFFFF)
        static let primaryContainer = Color(hex: 0x4A7C59)
        static let onPrimaryContainer = Color(hex: 0xE1FFE5)
        static let primaryFixed = Color(hex: 0xB9EFC5)

        // Secondary — soft mint. Confirmed / done states.
        static let secondaryContainer = Color(hex: 0xC0ECDC)
        static let onSecondaryContainer = Color(hex: 0x264E42)

        // Tertiary — gentle blue. Information, never urgency.
        static let tertiary = Color(hex: 0x405D6A)
        static let tertiaryContainer = Color(hex: 0xC8E7F7)
        static let onTertiaryContainer = Color(hex: 0x2D4B57)

        /// Amber. Possible concerns and anything awaiting the user's judgement.
        /// Tuned to sit inside the palette's muted register rather than shout over it.
        static let concern = Color(hex: 0x8A6220)
        static let concernContainer = Color(hex: 0xF9EEDC)
        static let onConcernContainer = Color(hex: 0x5C3F0F)

        /// Reserved for genuine failures — a vault that will not open, a notification that will
        /// not schedule. Never used for clinical content.
        static let error = Color(hex: 0xBA1A1A)
        static let errorContainer = Color(hex: 0xFFDAD6)

        static let outline = Color(hex: 0x717971)
        static let outlineVariant = Color(hex: 0xC1C9BF)
        static let hairline = Color(hex: 0xE2E8F0)
    }

    // MARK: - Typography

    enum Typeface {
        static func displayLarge() -> Font { .system(size: 32, weight: .semibold) }
        static func headlineMedium() -> Font { .system(size: 24, weight: .semibold) }
        static func headlineSmall() -> Font { .system(size: 20, weight: .semibold) }
        static func titleLarge() -> Font { .system(size: 18, weight: .medium) }
        static func bodyLarge() -> Font { .system(size: 16, weight: .regular) }
        static func bodyMedium() -> Font { .system(size: 14, weight: .regular) }
        static func labelMedium() -> Font { .system(size: 12, weight: .medium) }
        static func labelSmall() -> Font { .system(size: 11, weight: .semibold) }
        /// Verbatim chart text. Monospaced so a quotation is visibly a quotation.
        static func verbatim() -> Font { .system(size: 14, weight: .regular, design: .monospaced) }
        /// The large clock time that anchors a reminder row.
        static func clock() -> Font { .system(size: 28, weight: .semibold) }
    }

    // MARK: - Metrics

    enum Metric {
        static let base: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let containerMargin: CGFloat = 20
        static let gutter: CGFloat = 16

        static let radiusSmall: CGFloat = 4
        static let radius: CGFloat = 8
        static let radiusMedium: CGFloat = 12
        static let radiusLarge: CGFloat = 16
        static let radiusXL: CGFloat = 24
    }

    /// Level 1 elevation from the spec: soft, diffused, never a hard drop shadow.
    static func cardShadow() -> some ViewModifier { CardShadow() }
}

private struct CardShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
    }
}

extension View {
    /// White card, large radius, ambient shadow — the spec's primary container.
    func remliCard(radius: CGFloat = RemliTheme.Metric.radiusLarge) -> some View {
        self
            .background(RemliTheme.Palette.surface, in: RoundedRectangle(cornerRadius: radius))
            .modifier(CardShadow())
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Shared components

/// States a reminder can be in, and how each one looks.
///
/// `needsTime` exists because it is the **most common state in real data**, not an edge case.
/// Synthea's records say "once daily" and stop. The mockup this design came from assumed every
/// reminder has a confident clock time; almost none do.
enum ReminderState {
    case proposed
    /// A time is filled in, but Remli picked it — the chart did not say when.
    case suggested
    case needsTime
    case active
    case onlyWhenNeeded
    case done
    case paused

    var label: String {
        switch self {
        // Kept to one short word or two wherever possible: these render uppercased in a pill
        // beside a 32pt clock, and anything longer wraps mid-word.
        case .proposed: return "Proposed"
        case .suggested: return "Suggested"
        case .needsTime: return "Set time"
        case .active: return "On"
        case .onlyWhenNeeded: return "As needed"
        case .done: return "Done"
        case .paused: return "Paused"
        }
    }

    var foreground: Color {
        switch self {
        case .proposed: return RemliTheme.Palette.onTertiaryContainer
        case .suggested: return RemliTheme.Palette.onTertiaryContainer
        case .needsTime: return RemliTheme.Palette.onConcernContainer
        case .active: return RemliTheme.Palette.onSecondaryContainer
        case .onlyWhenNeeded: return RemliTheme.Palette.onSurfaceVariant
        case .done: return RemliTheme.Palette.onSecondaryContainer
        case .paused: return RemliTheme.Palette.onSurfaceMuted
        }
    }

    var background: Color {
        switch self {
        case .proposed, .suggested: return RemliTheme.Palette.tertiaryContainer
        case .needsTime: return RemliTheme.Palette.concernContainer
        case .active, .done: return RemliTheme.Palette.secondaryContainer
        case .onlyWhenNeeded, .paused: return RemliTheme.Palette.surfaceContainer
        }
    }
}

struct StatusChip: View {
    let state: ReminderState

    var body: some View {
        Text(state.label.uppercased())
            .font(RemliTheme.Typeface.labelSmall())
            .kerning(0.6)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(state.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(state.background, in: Capsule())
    }
}

/// Says where a claim came from. Present on every clinical statement, without exception.
struct ProvenanceBadge: View {
    let provenance: Provenance

    private var tint: Color {
        switch provenance {
        case .fromYourRecord: return RemliTheme.Palette.primary
        case .patternNoticed: return RemliTheme.Palette.onSurfaceVariant
        case .needsReview: return RemliTheme.Palette.concern
        case .convenienceSuggestion: return RemliTheme.Palette.tertiary
        }
    }

    private var background: Color {
        switch provenance {
        case .fromYourRecord: return RemliTheme.Palette.primaryFixed.opacity(0.5)
        case .patternNoticed: return RemliTheme.Palette.surfaceContainer
        case .needsReview: return RemliTheme.Palette.concernContainer
        case .convenienceSuggestion: return RemliTheme.Palette.tertiaryContainer
        }
    }

    var body: some View {
        Text(provenance.badgeText)
            .font(RemliTheme.Typeface.labelSmall())
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
            .accessibilityLabel("Source: \(provenance.badgeText)")
    }
}

/// A block of text quoted exactly from the record, with its attribution.
struct VerbatimQuote: View {
    let label: String
    let text: String
    let citation: SourceCitation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(RemliTheme.Typeface.labelSmall())
                .kerning(0.5)
                .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)

            Text(text)
                .font(RemliTheme.Typeface.verbatim())
                .foregroundStyle(RemliTheme.Palette.onSurface)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                Text(citation.chipLabel)
                if citation.dataOrigin != .liveFHIR {
                    Text("· \(citation.dataOrigin.shortLabel)")
                }
            }
            .font(RemliTheme.Typeface.labelSmall())
            .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RemliTheme.Metric.sm)
        .background(
            RemliTheme.Palette.surfaceLow,
            in: RoundedRectangle(cornerRadius: RemliTheme.Metric.radiusMedium)
        )
    }
}

/// A possible concern or informational note.
struct FlagRow: View {
    let flag: ProposalFlag

    private var isConcern: Bool { flag.severity == .possibleConcern }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isConcern ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 14))
                .foregroundStyle(isConcern
                                 ? RemliTheme.Palette.concern
                                 : RemliTheme.Palette.tertiary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(flag.title)
                    .font(RemliTheme.Typeface.bodyMedium().weight(.medium))
                    .foregroundStyle(RemliTheme.Palette.onSurface)

                Text(flag.detail)
                    .font(RemliTheme.Typeface.bodyMedium())
                    .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                if let action = flag.suggestedAction {
                    Text(action)
                        .font(RemliTheme.Typeface.bodyMedium())
                        .foregroundStyle(isConcern
                                         ? RemliTheme.Palette.concern
                                         : RemliTheme.Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .padding(RemliTheme.Metric.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isConcern ? RemliTheme.Palette.concernContainer : RemliTheme.Palette.surfaceLow,
            in: RoundedRectangle(cornerRadius: RemliTheme.Metric.radiusMedium)
        )
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RemliTheme.Typeface.bodyMedium().weight(.semibold))
            .foregroundStyle(RemliTheme.Palette.onPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, RemliTheme.Metric.sm)
            .background(
                RemliTheme.Palette.primary,
                in: RoundedRectangle(cornerRadius: RemliTheme.Metric.radius)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct OutlineButtonStyle: ButtonStyle {
    var tint: Color = RemliTheme.Palette.onSurface

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RemliTheme.Typeface.bodyMedium().weight(.medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, RemliTheme.Metric.sm)
            .background(
                RemliTheme.Palette.surface,
                in: RoundedRectangle(cornerRadius: RemliTheme.Metric.radius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RemliTheme.Metric.radius)
                    .stroke(RemliTheme.Palette.hairline, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var tint: Color = RemliTheme.Palette.onSurfaceMuted

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(RemliTheme.Typeface.bodyMedium().weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, RemliTheme.Metric.sm)
            .padding(.vertical, RemliTheme.Metric.xs)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
