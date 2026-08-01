import SwiftUI

/// The visual language for a calm health aide.
///
/// The design doc asks for something that reads as "a private conversation", not a support chat.
/// Practically that means: low-contrast warm neutrals rather than clinical white, generous line
/// height, no hard-edged alert colors except where a genuine concern needs to be seen, and type
/// that stays legible for someone reading a medication instruction without their glasses on.
enum NudgyTheme {

    // MARK: - Color

    enum Palette {
        /// Warm off-white. Pure white reads as clinical and is harsher at 6am.
        static let canvas = Color(hex: 0xF7F5F2)
        static let surface = Color(hex: 0xFFFFFF)
        static let surfaceSunken = Color(hex: 0xF1EEE9)

        static let ink = Color(hex: 0x2A2724)
        static let inkSecondary = Color(hex: 0x6B655E)
        static let inkTertiary = Color(hex: 0x9A938A)

        /// Muted sage. Used for on-device/privacy affirmations — calm, not celebratory.
        static let trust = Color(hex: 0x5C7A6B)
        static let trustSoft = Color(hex: 0xE4EBE6)

        /// Warm clay for the assistant's own voice.
        static let accent = Color(hex: 0xB5714F)
        static let accentSoft = Color(hex: 0xF6E9E1)

        /// Deliberately amber rather than red. A source disagreement is something to look at with
        /// your care team, not an emergency, and red would overstate it.
        static let concern = Color(hex: 0x9A6B22)
        static let concernSoft = Color(hex: 0xFAF0DC)

        static let hairline = Color(hex: 0xE5E0D9)
    }

    // MARK: - Type

    enum Typeface {
        static func title() -> Font { .system(.title2, design: .serif).weight(.semibold) }
        static func cardTitle() -> Font { .system(.headline, design: .serif) }
        /// Assistant prose. Serif at a comfortable size — this is the voice of the product.
        static func body() -> Font { .system(.body, design: .serif) }
        static func ui() -> Font { .system(.subheadline) }
        static func label() -> Font { .system(.footnote, design: .rounded).weight(.medium) }
        static func micro() -> Font { .system(.caption2, design: .rounded).weight(.semibold) }
        /// Verbatim chart text. Monospaced so a quoted instruction is visibly a quotation.
        static func verbatim() -> Font { .system(.footnote, design: .monospaced) }
    }

    // MARK: - Metrics

    enum Metric {
        static let gutter: CGFloat = 20
        static let cardRadius: CGFloat = 18
        static let chipRadius: CGFloat = 9
        static let stackGap: CGFloat = 14
        static let tightGap: CGFloat = 6
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

// MARK: - Shared building blocks

/// The small tag that states where a claim came from. Used everywhere a clinical statement appears.
struct ProvenanceBadge: View {
    let provenance: Provenance

    private var tint: Color {
        switch provenance {
        case .fromYourRecord: return NudgyTheme.Palette.trust
        case .patternNoticed: return NudgyTheme.Palette.inkSecondary
        case .needsReview: return NudgyTheme.Palette.concern
        case .convenienceSuggestion: return NudgyTheme.Palette.accent
        }
    }

    private var background: Color {
        switch provenance {
        case .fromYourRecord: return NudgyTheme.Palette.trustSoft
        case .patternNoticed: return NudgyTheme.Palette.surfaceSunken
        case .needsReview: return NudgyTheme.Palette.concernSoft
        case .convenienceSuggestion: return NudgyTheme.Palette.accentSoft
        }
    }

    var body: some View {
        Text(provenance.badgeText.uppercased())
            .font(NudgyTheme.Typeface.micro())
            .kerning(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: NudgyTheme.Metric.chipRadius))
            .accessibilityLabel("Source: \(provenance.badgeText)")
    }
}

/// A block of text quoted exactly from the record, with its attribution.
///
/// Verbatim display is a safety feature, not a stylistic one — see ARCHITECTURE.md §3.
struct VerbatimQuote: View {
    let label: String
    let text: String
    let citation: SourceCitation

    var body: some View {
        VStack(alignment: .leading, spacing: NudgyTheme.Metric.tightGap) {
            Text(label.uppercased())
                .font(NudgyTheme.Typeface.micro())
                .kerning(0.5)
                .foregroundStyle(NudgyTheme.Palette.inkTertiary)

            Text(text)
                .font(NudgyTheme.Typeface.verbatim())
                .foregroundStyle(NudgyTheme.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                Text(citation.chipLabel)
                if citation.dataOrigin != .liveFHIR {
                    Text("· \(citation.dataOrigin.shortLabel)")
                }
            }
            .font(NudgyTheme.Typeface.micro())
            .foregroundStyle(NudgyTheme.Palette.inkTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            NudgyTheme.Palette.surfaceSunken,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

/// A possible concern or informational note attached to a proposal.
struct FlagRow: View {
    let flag: ProposalFlag

    private var tint: Color {
        flag.severity == .possibleConcern
            ? NudgyTheme.Palette.concern
            : NudgyTheme.Palette.inkSecondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: flag.severity == .possibleConcern
                  ? "exclamationmark.triangle"
                  : "info.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(flag.title)
                    .font(NudgyTheme.Typeface.label())
                    .foregroundStyle(NudgyTheme.Palette.ink)

                Text(flag.detail)
                    .font(NudgyTheme.Typeface.ui())
                    .foregroundStyle(NudgyTheme.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let action = flag.suggestedAction {
                    Text(action)
                        .font(NudgyTheme.Typeface.ui().italic())
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            flag.severity == .possibleConcern
                ? NudgyTheme.Palette.concernSoft
                : NudgyTheme.Palette.surfaceSunken,
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

/// Primary/secondary buttons sized for a calm, unhurried decision.
struct CalmButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary, quiet }
    var emphasis: Emphasis = .secondary

    func makeBody(configuration: Configuration) -> some View {
        let (fg, bg): (Color, Color) = {
            switch emphasis {
            case .primary: return (.white, NudgyTheme.Palette.trust)
            case .secondary: return (NudgyTheme.Palette.ink, NudgyTheme.Palette.surfaceSunken)
            case .quiet: return (NudgyTheme.Palette.inkSecondary, .clear)
            }
        }()

        return configuration.label
            .font(NudgyTheme.Typeface.label())
            .foregroundStyle(fg)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(bg, in: Capsule())
            .overlay {
                if emphasis == .quiet {
                    Capsule().stroke(NudgyTheme.Palette.hairline, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
