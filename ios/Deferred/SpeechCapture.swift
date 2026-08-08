import AVFoundation
import Foundation
import Speech

/// Why dictation is not available right now, in a form the status strip can show verbatim.
///
/// These strings reach the screen, so they explain rather than accuse, and none of them names
/// anything the user said.
enum SpeechCaptureError: Error, LocalizedError, Equatable {
    /// The system has no recognizer for this locale at all.
    case localeUnsupported(identifier: String)
    /// **The privacy stop.** The locale can be recognized, but only by sending audio to Apple.
    case onDeviceRecognitionUnsupported(identifier: String)
    /// The user declined speech recognition, or it is restricted by policy.
    case speechAuthorizationDenied
    /// The user declined microphone access.
    case microphoneDenied
    /// The recognizer exists but is momentarily unavailable (system busy, assets loading).
    case recognizerTemporarilyUnavailable
    /// No usable input hardware — the common case is a simulator with no host microphone.
    case noAudioInput
    case audioSessionFailed(underlyingDescription: String)
    case audioEngineFailed(underlyingDescription: String)
    case recognitionFailed(underlyingDescription: String)

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let identifier):
            return "Remli can't transcribe \(identifier) speech on this phone. You can still type."
        case .onDeviceRecognitionUnsupported(let identifier):
            return """
            Voice input is off for \(identifier). This phone can only transcribe that language by \
            sending your voice to Apple's servers, and Remli won't send health conversations off \
            this device. You can still type, and everything else works normally.
            """
        case .speechAuthorizationDenied:
            return """
            Speech recognition is turned off for Remli. You can turn it on in Settings › Remli, or \
            keep using text.
            """
        case .microphoneDenied:
            return """
            Microphone access is turned off for Remli. You can turn it on in Settings › Remli, or \
            keep using text.
            """
        case .recognizerTemporarilyUnavailable:
            return "Voice input isn't ready yet. Try again in a moment, or type instead."
        case .noAudioInput:
            return "No microphone is available on this device. You can still type."
        case .audioSessionFailed(let underlying):
            return "Audio setup failed: \(underlying)"
        case .audioEngineFailed(let underlying):
            return "The microphone could not start: \(underlying)"
        case .recognitionFailed(let underlying):
            return "Transcription stopped: \(underlying)"
        }
    }

    /// True when the user can fix this in Settings.
    var isFixableBySettings: Bool {
        self == .speechAuthorizationDenied || self == .microphoneDenied
    }
}

/// On-device dictation for the composer.
///
/// # The one rule
///
/// **`requiresOnDeviceRecognition` is always `true`, and if the device cannot honour it, dictation
/// is disabled rather than downgraded.**
///
/// `SFSpeechRecognizer` will happily stream audio to Apple's servers. That is a reasonable default
/// for a notes app and a product-ending default for this one: the sentences spoken into Remli are
/// "my knee still hurts after the Tuesday exercises" and "I skipped the metformin again". Sending
/// those anywhere contradicts the single promise the product makes, and it would do so invisibly —
/// the transcript comes back looking exactly the same either way. That is what makes a silent
/// fallback so dangerous, and why it is refused here.
///
/// So the flow is: check `SFSpeechRecognizer.supportsOnDeviceRecognition` *before* starting; if it
/// is false, publish `.unavailable(reason:)` with an honest explanation and never open the
/// microphone. `requiresOnDeviceRecognition = true` is then set on the request as well, so even a
/// wrong answer from the capability check ends in an error from the system rather than in a network
/// request. Text input remains fully available; the design doc makes voice *primary* for quick
/// capture, not mandatory.
///
/// `supportsOnDeviceRecognition` can flip to true after iOS finishes downloading the locale's
/// on-device assets, so `refreshAvailability()` is re-run rather than cached for the session.
///
/// # Lifecycle
///
/// `start()` twice is a no-op the second time; `stop()` before `start()` is a no-op. Teardown always
/// removes the tap, stops the engine, cancels the task, and deactivates the session, including on
/// every error path — a leaked tap makes the *next* start fail with a format mismatch, which is a
/// miserable bug to find on stage.
@MainActor
final class SpeechCapture: NSObject, ObservableObject {

    // MARK: - Published state

    /// Drives the status strip's microphone indicator. Mirrors reality, including the
    /// `.unavailable(reason:)` case, which is the on-device refusal above.
    @Published private(set) var microphoneState: SessionStatus.MicrophoneState = .off

    /// Live partial transcript. Rewritten as the recognizer revises its hypothesis.
    @Published private(set) var partialTranscript: String = ""

    /// The last completed utterance, published when recognition finalizes after `stop()`.
    @Published private(set) var finalTranscript: String = ""

    /// True between `start()` and teardown. Distinct from `microphoneState` so the UI can show a
    /// "starting" moment without claiming the mic is live.
    @Published private(set) var isListening: Bool = false

    /// Nil when dictation is usable. Otherwise the reason, ready to display.
    @Published private(set) var unavailability: SpeechCaptureError?

    /// Set once `prepare()` has run, so the UI can distinguish "not asked yet" from "not allowed".
    @Published private(set) var hasPrepared: Bool = false

    // MARK: - Configuration

    let locale: Locale

    // MARK: - Private

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapIsInstalled = false
    private var sessionIsActive = false
    private var onFinalTranscript: ((String) -> Void)?

    /// - Parameter locale: defaults to the user's current locale. Passing an explicit locale is how
    ///   the app offers a language picker later without changing anything here.
    init(locale: Locale = Locale.current) {
        self.locale = locale
        self.recognizer = SFSpeechRecognizer(locale: locale)
        super.init()
        recognizer?.delegate = self
        // Deliver recognition callbacks on the main queue so published state updates in order.
        recognizer?.queue = .main
    }

    deinit {
        // `deinit` is nonisolated, so no main-actor work here. Detaching the engine's tap is the
        // only thing that matters and the engine deallocates with it.
        audioEngine.stop()
    }

    // MARK: - Permissions and availability

    /// Requests both permissions Remli needs, then evaluates whether on-device dictation is possible.
    ///
    /// Speech recognition and the microphone are two separate grants with two separate Info.plist
    /// strings; granting one and denying the other is a normal state, so both are asked for and both
    /// are checked.
    @discardableResult
    func prepare() async -> SpeechCaptureError? {
        let speechStatus = await Self.requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            hasPrepared = true
            return publish(.speechAuthorizationDenied)
        }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            hasPrepared = true
            return publish(.microphoneDenied)
        }

        hasPrepared = true
        return refreshAvailability()
    }

    /// Re-checks availability without prompting. Cheap; call it when the composer appears.
    ///
    /// The on-device check lives here rather than in `prepare()` alone because
    /// `supportsOnDeviceRecognition` is not constant — it becomes true once iOS has downloaded the
    /// locale's speech assets, which can happen minutes after first launch.
    @discardableResult
    func refreshAvailability() -> SpeechCaptureError? {
        guard let recognizer else {
            return publish(.localeUnsupported(identifier: displayLanguage))
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return publish(.speechAuthorizationDenied)
        }
        guard AVAudioApplication.shared.recordPermission == .granted else {
            return publish(.microphoneDenied)
        }

        // ── The privacy gate ────────────────────────────────────────────────────────────────────
        // If this is false, the only way to transcribe this locale is Apple's servers. We stop here
        // instead. Nothing below this line ever runs with server-side recognition.
        guard recognizer.supportsOnDeviceRecognition else {
            return publish(.onDeviceRecognitionUnsupported(identifier: displayLanguage))
        }
        // ────────────────────────────────────────────────────────────────────────────────────────

        guard recognizer.isAvailable else {
            return publish(.recognizerTemporarilyUnavailable)
        }

        return publish(nil)
    }

    // MARK: - Capture

    /// Opens the microphone and begins publishing partial transcripts.
    ///
    /// - Parameter onFinalTranscript: called once, on the main actor, with the completed utterance.
    ///   `finalTranscript` is published at the same moment; the closure exists so the composer can
    ///   send the text without observing state it does not otherwise care about.
    func start(onFinalTranscript: ((String) -> Void)? = nil) async throws {
        // Started twice: keep the first session rather than tearing down mid-sentence.
        guard !isListening else { return }

        if !hasPrepared {
            if let blocked = await prepare() { throw blocked }
        }
        if let blocked = refreshAvailability() { throw blocked }
        guard let recognizer else { throw SpeechCaptureError.localeUnsupported(identifier: displayLanguage) }

        self.onFinalTranscript = onFinalTranscript
        partialTranscript = ""

        do {
            try activateSession()
        } catch let error as SpeechCaptureError {
            teardown(finalState: .unavailable(reason: error.errorDescription ?? "Audio unavailable"))
            throw error
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        // Mandatory. Set even though `refreshAvailability()` just proved it is supported: if that
        // check is ever wrong, this turns a silent upload into a loud error.
        request.requiresOnDeviceRecognition = true
        // Partials are the whole point of live dictation — the user watches the words appear and
        // knows the mic is really on.
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            teardown(finalState: .unavailable(reason: SpeechCaptureError.noAudioInput.errorDescription ?? ""))
            throw SpeechCaptureError.noAudioInput
        }

        // The tap runs on a realtime audio thread. It does exactly one thing, and that one thing is
        // documented as safe to call from there.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapIsInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            let failure = SpeechCaptureError.audioEngineFailed(underlyingDescription: error.localizedDescription)
            teardown(finalState: .unavailable(reason: failure.errorDescription ?? ""))
            throw failure
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Hops back to the main actor rather than asserting we are already on it. Tasks queued
            // to the same actor run in order, so partials stay in sequence.
            Task { @MainActor [weak self] in
                self?.handle(result: result, error: error)
            }
        }

        isListening = true
        microphoneState = .listening
        unavailability = nil
    }

    /// Ends the utterance. Audio stops immediately; the final transcript arrives shortly after, once
    /// the recognizer has finished with the buffers it already has.
    ///
    /// Safe to call when nothing is running.
    func stop() {
        guard isListening else { return }
        // Stop feeding audio, but leave the recognition task alive so it can produce `isFinal`.
        audioEngine.stop()
        removeTapIfNeeded()
        request?.endAudio()
        isListening = false
        microphoneState = .off
    }

    /// Abandons the utterance and discards the partial transcript. Used when the user backs out of
    /// the composer, or when the app leaves the foreground.
    func cancel() {
        recognitionTask?.cancel()
        teardown(finalState: .off)
        partialTranscript = ""
        onFinalTranscript = nil
    }

    // MARK: - Recognition callbacks

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                finalTranscript = text
                partialTranscript = ""
                let callback = onFinalTranscript
                onFinalTranscript = nil
                teardown(finalState: .off)
                callback?(text)
                return
            }
            partialTranscript = text
        }

        if let error {
            // A cancelled task reports an error too; that is a normal user action, not a failure.
            let nsError = error as NSError
            let wasCancelled = nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
            if !wasCancelled {
                // Keep whatever the user already said. Losing a half-finished sentence to a
                // transient recognizer hiccup is worse than showing a partial.
                if !partialTranscript.isEmpty {
                    finalTranscript = partialTranscript
                    let callback = onFinalTranscript
                    onFinalTranscript = nil
                    callback?(partialTranscript)
                    partialTranscript = ""
                }
                unavailability = .recognitionFailed(underlyingDescription: error.localizedDescription)
            }
            teardown(finalState: .off)
        }
    }

    // MARK: - Audio session

    /// Configures the shared session for dictation that coexists with read-back.
    ///
    /// `.playAndRecord` rather than `.record` so `SpeechPlayback` can speak without either side
    /// having to tear the session down and rebuild it — swapping categories mid-conversation is
    /// audible as a click and occasionally drops the first syllable. `.spokenAudio` is the mode
    /// intended for voice content, `.duckOthers` lowers music instead of killing it, and
    /// `.defaultToSpeaker` keeps a hands-free reminder audible when nothing is plugged in.
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: [])
            sessionIsActive = true
        } catch {
            throw SpeechCaptureError.audioSessionFailed(underlyingDescription: error.localizedDescription)
        }
    }

    /// Full cleanup. Idempotent, and safe to call from any state including "never started".
    private func teardown(finalState: SessionStatus.MicrophoneState) {
        if audioEngine.isRunning { audioEngine.stop() }
        removeTapIfNeeded()
        request?.endAudio()
        request = nil
        recognitionTask = nil
        isListening = false

        if sessionIsActive {
            // `.notifyOthersOnDeactivation` lets whatever we ducked come back up cleanly.
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            sessionIsActive = false
        }

        microphoneState = finalState
    }

    private func removeTapIfNeeded() {
        guard tapIsInstalled else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        tapIsInstalled = false
    }

    // MARK: - Helpers

    /// Publishes an availability verdict and mirrors it into the microphone state. Returns the same
    /// error so callers can `if let blocked = publish(...)`.
    @discardableResult
    private func publish(_ error: SpeechCaptureError?) -> SpeechCaptureError? {
        unavailability = error
        if let error {
            microphoneState = .unavailable(reason: error.errorDescription ?? "Voice input unavailable")
        } else if !isListening {
            microphoneState = .off
        }
        return error
    }

    /// Human-readable language name for error copy — "English (United States)", not "en_US".
    private var displayLanguage: String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            // The handler is explicitly not guaranteed to run on the main queue.
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

// MARK: - SFSpeechRecognizerDelegate

extension SpeechCapture: SFSpeechRecognizerDelegate {
    /// The recognizer can drop out and come back — assets loading, system pressure, locale changes.
    /// The status strip should follow it rather than showing a stale "ready".
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if available {
                self.refreshAvailability()
            } else if !self.isListening {
                self.publish(.recognizerTemporarilyUnavailable)
            }
        }
    }
}
