import Foundation
import os

#if canImport(LiteRTLM)
import LiteRTLM
#endif

// MARK: - Always-compiled facts about the runtime

/// Everything the rest of the app is allowed to know about LiteRT-LM without linking it.
///
/// This enum compiles whether or not the package is present, so `LanguageModelProvider` and the
/// settings screen can explain *why* Gemma is not running without being conditionally compiled
/// themselves.
enum LiteRTRuntime {

    /// True when the LiteRT-LM Swift package is linked into this target.
    static var isLinked: Bool {
        #if canImport(LiteRTLM)
        return true
        #else
        return false
        #endif
    }

    /// True when this build can host inference at all. The simulator cannot: LiteRT-LM's
    /// CPU/XNNPACK path throws `INTERNAL` on first generation and the GPU path cannot create an
    /// engine (google-ai-edge/LiteRT-LM issue #2504). Fighting that would waste the demo; Nudgy
    /// detects it and says so.
    static var canRunInference: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return isLinked
        #endif
    }

    static let packageURL = "https://github.com/google-ai-edge/LiteRT-LM"

    static let simulatorExplanation =
        "Gemma runs on a physical iPhone; this is scripted narration. "
        + "LiteRT-LM cannot run inference in the iOS Simulator."

    static let missingPackageExplanation =
        "The LiteRT-LM Swift package is not linked into this build, so narration is scripted. "
        + "Add \(packageURL) in Xcode under File ▸ Add Package Dependencies to enable Gemma."

    /// KV-cache size, in tokens, covering **prompt *and* reply** — not just the reply.
    ///
    /// This was 512, sized against "1–3 short sentences of output". That was the wrong quantity:
    /// the cache also has to hold the system message, the few-shot examples, and the grounded
    /// facts, which together run well past 512. The symptom was not an error naming the cause but
    /// `sendMessage` returning null from the native layer, which surfaced as scripted replies from
    /// an engine that had loaded perfectly.
    ///
    /// 4096 is still small against Gemma 4's 128K context and costs little memory, while leaving
    /// generous headroom over the longest prompt Nudgy builds.
    static let maxNumTokens = 4096

    /// Low on purpose. Nudgy is not looking for creative phrasing — every extra degree of
    /// sampling entropy is another chance at an invented number that `SafetyGuard` then has to
    /// catch, and a rejection costs the user warmth. Warmth comes from the prompt, not the heat.
    static let temperature: Float = 0.35
    static let topK = 40
    static let topP: Float = 0.95
}

// MARK: - Serialisation

/// A one-at-a-time gate around generation.
///
/// A single LiteRT-LM engine is not something to drive from two places at once, and Nudgy has an
/// obvious way to end up doing exactly that: a proposal introduction still streaming when the user
/// taps a card and asks a follow-up. Requests queue instead of racing.
///
/// Deliberately outside the `#if canImport` block so it compiles and can be reasoned about without
/// the package present.
actor GenerationGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
            return
        }
        // Hand the gate straight to the next waiter; `isBusy` stays true because it now holds it.
        waiters.removeFirst().resume()
    }
}

/// Implemented by any model holding reclaimable memory.
protocol LiteRTUnloadable: AnyObject {
    func unload()
}

// MARK: - The real thing

#if canImport(LiteRTLM)

/// Gemma 4 E2B, running on this phone, through LiteRT-LM.
///
/// It does exactly one thing: turn a `GroundedPrompt` into raw text. It does not build prompts
/// (`GroundedPromptBuilder` does), it does not decide what is safe (`SafetyGuard` does), and it
/// never sees a `ReminderProposal` field it could accidentally alter. Every path out of this type
/// goes through `NarrationPipeline`, which is where the guard lives — so there is no way to add a
/// method here that quietly skips review.
final class LiteRTGemmaModel: NudgyLanguageModel, LiteRTUnloadable {

    enum Backend: String {
        case gpu
        case cpu

        var displayName: String { self == .gpu ? "GPU" : "CPU" }
    }

    let isOnDevice = true

    var displayName: String {
        guard let backend = activeBackend else { return "Gemma 4 E2B · on device" }
        return "Gemma 4 E2B · on device (\(backend.displayName))"
    }

    var availabilityNote: String? {
        guard let backend = activeBackend else { return nil }
        return backend == .cpu
            ? "The GPU backend would not start, so Gemma is running on the CPU. Replies will be slower."
            : nil
    }

    private let modelManager: GemmaModelManager
    private let gate = GenerationGate()

    private var engine: Engine?
    private(set) var activeBackend: Backend?
    /// Memoised so ten call sites calling `prepare()` produce one engine, not ten.
    private var preparation: Task<Void, Error>?

    init(modelManager: GemmaModelManager = .shared) {
        self.modelManager = modelManager
    }

    // MARK: Lifecycle

    /// Loads weights and starts an engine. Expensive (hundreds of milliseconds to seconds and
    /// ~1.45 GB resident on GPU), so it is never called from app launch — the provider calls it
    /// the first time narration is actually wanted.
    func prepare() async throws {
        DiagnosticLog.note("prepare: begin engine=\(self.engine == nil ? "nil" : "ready")"); LanguageModelProvider.log.info("prepare: begin, engine=\(self.engine == nil ? "nil" : "ready", privacy: .public)")
        if engine != nil { return }
        if let preparation {
            try await preparation.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { throw LanguageModelError.cancelled }
            try await self.loadEngine()
        }
        preparation = task
        do {
            try await task.value
        } catch {
            // Let a later attempt retry rather than caching the failure forever: the usual cause
            // is "the download had not finished yet".
            preparation = nil
            throw error
        }
    }

    /// Drops the engine, freeing its memory. Call on a memory warning; `prepare()` rebuilds it.
    func unload() {
        engine = nil
        activeBackend = nil
        preparation = nil
    }

    private func loadEngine() async throws {
        #if targetEnvironment(simulator)
        throw LanguageModelError.unsupportedEnvironment(LiteRTRuntime.simulatorExplanation)
        #else
        guard let modelURL = modelManager.readyModelURL else {
            DiagnosticLog.note("loadEngine: NO MODEL URL availability=\(String(describing: self.modelManager.availability))"); LanguageModelProvider.log.error("loadEngine: no ready model URL — manager says \(String(describing: self.modelManager.availability), privacy: .public)")
            throw LanguageModelError.modelFileMissing
        }
        DiagnosticLog.note("loadEngine: model at \(modelURL.path)"); LanguageModelProvider.log.info("loadEngine: model at \(modelURL.lastPathComponent, privacy: .public)")

        var failures: [String] = []
        // GPU first: 56.5 tok/s decode and 0.3 s TTFT on an iPhone 17 Pro, against a CPU backend
        // that is markedly slower but needs only ~607 MB. Falling back rather than failing means a
        // memory-constrained phone still gets real Gemma, just at a slower cadence.
        for backend in [Backend.gpu, Backend.cpu] {
            do {
                let engineConfig = try EngineConfig(
                    modelPath: modelURL.path,
                    backend: backend == .gpu ? .gpu : .cpu(),
                    maxNumTokens: LiteRTRuntime.maxNumTokens,
                    cacheDir: NSTemporaryDirectory()
                )
                let engine = Engine(engineConfig: engineConfig)
                try await engine.initialize()
                DiagnosticLog.note("loadEngine: \(backend.displayName) INITIALISED"); LanguageModelProvider.log.info("loadEngine: \(String(describing: backend), privacy: .public) backend initialised")
                self.engine = engine
                self.activeBackend = backend
                return
            } catch {
                DiagnosticLog.note("loadEngine: \(backend.displayName) FAILED — \(error.localizedDescription)")
                LanguageModelProvider.log.error(
                    "loadEngine: \(backend.displayName, privacy: .public) failed — \(error.localizedDescription, privacy: .public)"
                )
                failures.append("\(backend.displayName): \(error.localizedDescription)")
            }
        }
        throw LanguageModelError.engineInitializationFailed(failures.joined(separator: " / "))
        #endif
    }

    // MARK: Narration

    func narrate(_ request: NarrationRequest) async throws -> NarrationResult {
        try await prepare()
        return try await NarrationPipeline.runReportingErrors(request: request) { prompt in
            try await self.generate(prompt)
        }
    }

    func narrateStream(_ request: NarrationRequest) -> AsyncThrowingStream<NarrationEvent, Error> {
        NarrationPipeline.stream(request: request) { prompt in
            self.rawTokenStream(for: prompt)
        }
    }

    // MARK: Generation

    private func generate(_ prompt: GroundedPrompt) async throws -> String {
        // Prepare on demand. `prepare()` is kicked off at launch but not awaited — it loads 2.4 GB
        // and blocking startup on it would be worse. Without this, any request arriving before it
        // finished threw, and the caller quietly fell back to a template: the model was loaded and
        // reported as ready, yet every early message was scripted.
        if engine == nil { try await prepare() }
        guard let engine else {
            throw LanguageModelError.engineInitializationFailed("No engine after prepare().")
        }
        await gate.acquire()
        defer { Task { await self.gate.release() } }

        do {
            DiagnosticLog.note("generate: sending, prompt chars=\(prompt.systemMessage.count + prompt.userMessage.count) budget=\(LiteRTRuntime.maxNumTokens) tokens"); LanguageModelProvider.log.info("generate: engine ready, sending")
            let config = try conversationConfig(for: prompt)
            let conversation = try await engine.createConversation(with: config)
            let response = try await conversation.sendMessage(Message(prompt.userMessage))
            return response.toString
        } catch {
            throw LanguageModelError.generationFailed(error.localizedDescription)
        }
    }

    private func rawTokenStream(for prompt: GroundedPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.prepare()
                    guard let engine = self.engine else {
                        throw LanguageModelError.engineInitializationFailed("No engine after prepare().")
                    }
                    await self.gate.acquire()
                    defer { Task { await self.gate.release() } }

                    let config = try self.conversationConfig(for: prompt)
                    let conversation = try await engine.createConversation(with: config)
                    for try await chunk in conversation.sendMessageStream(Message(prompt.userMessage)) {
                        if Task.isCancelled { break }
                        continuation.yield(chunk.toString)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LanguageModelError.generationFailed(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Raw completion for structured output — reminder times, not prose.
    ///
    /// Deliberately not routed through `GroundedPromptBuilder`: there is no narration here to
    /// ground, and no sentence for SafetyGuard to read. The caller validates the result against a
    /// schema instead, and falls back to deterministic spacing if anything is off. Temperature is
    /// dropped well below the narration setting because this is a constrained-format answer, not
    /// a piece of writing.
    func completeRaw(prompt: String) async throws -> String {
        if engine == nil { try await prepare() }
        guard let engine else {
            throw LanguageModelError.engineInitializationFailed("No engine after prepare().")
        }
        await gate.acquire()
        defer { Task { await self.gate.release() } }

        let sampler = try SamplerConfig(topK: 20, topP: 0.9, temperature: 0.2)
        let config = ConversationConfig(
            systemMessage: Message(
                "You output only what is asked, in exactly the format requested. "
                + "No commentary, no preamble, no explanation."
            ),
            samplerConfig: sampler
        )
        do {
            let conversation = try await engine.createConversation(with: config)
            return try await conversation.sendMessage(Message(prompt)).toString
        } catch {
            throw LanguageModelError.generationFailed(error.localizedDescription)
        }
    }

    /// A fresh conversation per request, carrying that request's system message.
    ///
    /// Not a long-lived chat session: history is a grounding leak. Turn three must not be able to
    /// restate a dose from turn one's medication, so every turn starts clean with exactly the one
    /// proposal it is about.
    private func conversationConfig(for prompt: GroundedPrompt) throws -> ConversationConfig {
        let samplerConfig = try SamplerConfig(
            topK: LiteRTRuntime.topK,
            topP: LiteRTRuntime.topP,
            temperature: LiteRTRuntime.temperature
        )
        return ConversationConfig(
            systemMessage: Message(prompt.systemMessage),
            samplerConfig: samplerConfig
        )
    }
}

#endif
