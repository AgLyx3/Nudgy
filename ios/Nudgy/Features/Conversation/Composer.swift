import SwiftUI

/// The input bar: quick actions and a text field.
///
/// The design doc originally made voice primary for quick capture. Dictation was cut from v1: it
/// sits outside the connect → cite → propose → approve → notify loop that the product is actually
/// judged on, and it carried the most failure modes of anything in the app. Typing is also the
/// right default for the thing people most often need to enter here — a dose they care about
/// getting exactly right. Spoken read-back of Nudgy's replies is retained.
///
/// The deferred capture implementation is preserved at `ios/Deferred/SpeechCapture.swift`.
struct Composer: View {
    @Binding var text: String

    var onSend: (String) -> Void
    var onQuickAction: (QuickAction) -> Void
    var onAddFromPhoto: () -> Void

    @FocusState private var isTextFocused: Bool

    enum QuickAction: String, CaseIterable, Identifiable {
        case reviewReminders
        case whatsDueToday
        case whereFrom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .reviewReminders: return "Review reminders"
            case .whatsDueToday: return "What's due today"
            case .whereFrom: return "Where did this come from"
            }
        }

        var prompt: String {
            switch self {
            case .reviewReminders: return "Can we go through my reminders?"
            case .whatsDueToday: return "What do I need to do today?"
            case .whereFrom: return "Where did these reminders come from?"
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            quickActions
            inputRow
        }
        .padding(.horizontal, NudgyTheme.Metric.gutter)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            NudgyTheme.Palette.canvas
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(NudgyTheme.Palette.hairline)
                        .frame(height: 1)
                }
        )
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(QuickAction.allCases) { action in
                    Button(action.title) { onQuickAction(action) }
                        .buttonStyle(CalmButtonStyle(emphasis: .quiet))
                }

                Button {
                    onAddFromPhoto()
                } label: {
                    Label("Add from photo", systemImage: "camera")
                }
                .buttonStyle(CalmButtonStyle(emphasis: .quiet))
            }
            .padding(.horizontal, 1)
        }
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                TextField("Ask privately…", text: $text, axis: .vertical)
                    .font(NudgyTheme.Typeface.ui())
                    .lineLimit(1...4)
                    .focused($isTextFocused)
                    .submitLabel(.send)
                    .onSubmit(send)

                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(NudgyTheme.Palette.trust)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send message")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(NudgyTheme.Palette.surface, in: Capsule())
            .overlay {
                Capsule().stroke(NudgyTheme.Palette.hairline, lineWidth: 1)
            }
        }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        text = ""
        isTextFocused = false
    }
}
