import AVFoundation
import Foundation

/// Reads assistant turns aloud, in the voice a careful health aide would use.
///
/// `AVSpeechSynthesizer` renders entirely on device — nothing is uploaded, nothing is cached
/// remotely — which is why it is the text-to-speech choice here and not a nicer-sounding cloud
/// voice. Read-back is the half of the voice loop that makes hands-busy use work: someone holding a
/// pill bottle can hear the reminder without looking at the screen.
///
/// # Why the configuration is what it is
///
/// The defaults are tuned for productivity, not for a health conversation. A rate of 0.5 with a
/// flat pitch reads a medication instruction like a train announcement. The adjustments here are
/// small and all in one direction — slower, slightly softer, with a beat of silence around each
/// utterance — because the design doc asks for calm and soothing, and because the sentences being
/// read are ones people need a moment to absorb.
///
/// # Sharing the microphone's session
///
/// `SpeechCapture` configures the shared `AVAudioSession` as `.playAndRecord`. When it has, this
/// type leaves the session completely alone: swapping the category mid-conversation clicks, and
/// tearing it down would end an in-progress dictation. Only when no such session exists does this
/// type configure a `.playback` session of its own, and it deactivates only the sessions it
/// activated.
///
/// The app layer should still stop capture before speaking — otherwise the recognizer transcribes
/// Remli talking to itself. `isSpeaking` exists partly so that coordination is possible.
@MainActor
final class SpeechPlayback: NSObject, ObservableObject {

    /// True while an utterance is being spoken. Drives the "stop reading" affordance.
    @Published private(set) var isSpeaking: Bool = false

    /// User preference for read-back. When false, `speak(_:)` is a no-op — the timeline still shows
    /// the text, so nothing is lost.
    @Published var isEnabled: Bool = true

    /// Slightly under `AVSpeechUtteranceDefaultSpeechRate` (0.5). Enough to sound unhurried, not so
    /// slow that it sounds like it is talking down to the listener.
    static let calmRate: Float = AVSpeechUtteranceDefaultSpeechRate * 0.92

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    /// True only when *this* type activated the audio session, so it never deactivates one that
    /// `SpeechCapture` owns.
    private var didActivateSession = false

    /// - Parameter languageCode: BCP-47 code for the voice. Defaults to the user's current language
    ///   so read-back matches the language the app is presented in.
    init(languageCode: String? = nil) {
        let code = languageCode ?? AVSpeechSynthesisVoice.currentLanguageCode()
        self.voice = Self.gentlestVoice(for: code)
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Speaking

    /// Speaks one assistant turn. A new utterance replaces whatever is currently being read, so
    /// tapping through the timeline does not queue up a backlog of stale sentences.
    func speak(_ text: String) {
        guard isEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        do {
            try activateSessionIfNeeded()
        } catch {
            // Read-back is an enhancement. If the session is unavailable — a call is in progress,
            // another app holds exclusive audio — stay quiet rather than surfacing an error for
            // something the user can simply read on screen.
            return
        }

        synthesizer.speak(utterance(for: trimmed))
        isSpeaking = true
    }

    /// Stops immediately. Safe to call when nothing is speaking.
    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        deactivateSessionIfOwned()
    }

    // MARK: - Utterance shaping

    private func utterance(for text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Self.calmRate
        // A hair below neutral. Lower reads as steadier and less bright; going further starts to
        // sound sombre, which is the wrong note for "time for your exercise".
        utterance.pitchMultiplier = 0.97
        utterance.volume = 0.9
        // A short breath before and after. Without the pre-delay the first syllable can be clipped
        // by the session ramping up, and the post-delay stops one turn from crowding the next.
        utterance.preUtteranceDelay = 0.15
        utterance.postUtteranceDelay = 0.25
        return utterance
    }

    /// Picks the best-sounding installed voice for the language.
    ///
    /// Premium and enhanced voices are downloaded by the user in iOS Settings, so most devices have
    /// only the compact one. Preferring them when present costs nothing and is the single largest
    /// improvement to how considerate the read-back sounds; falling back to the default voice keeps
    /// this working everywhere.
    private static func gentlestVoice(for languageCode: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == languageCode }
        if let premium = candidates.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = candidates.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: languageCode) ?? candidates.first
    }

    // MARK: - Audio session

    /// Configures a playback session only when nobody else has already set one up.
    private func activateSessionIfNeeded() throws {
        let session = AVAudioSession.sharedInstance()
        // `.playAndRecord` means `SpeechCapture` owns the session. Leave it exactly as it is.
        if session.category == .playAndRecord || session.category == .playback {
            return
        }
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true, options: [])
        didActivateSession = true
    }

    private func deactivateSessionIfOwned() {
        guard didActivateSession else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        didActivateSession = false
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechPlayback: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.deactivateSessionIfOwned()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.deactivateSessionIfOwned()
        }
    }
}
