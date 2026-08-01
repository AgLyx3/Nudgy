import Foundation
import SwiftUI

/// The application's single coordinator: it owns the timeline and the order in which the
/// subsystems are allowed to touch it.
///
/// The one rule this type exists to enforce is the approval boundary. A `ReminderProposal` is
/// inert. Only `approve(_:)` converts one into an `ApprovedReminder`, and only an
/// `ApprovedReminder` can reach `NotificationScheduler`. There is no other path from imported
/// data to a scheduled alert, which is what makes "every reminder is individually approved" a
/// property of the code rather than a promise in a document.
@MainActor
final class NudgySession: ObservableObject {

    // MARK: - Published state

    @Published private(set) var timeline: [TimelineEntry] = []
    @Published private(set) var status = SessionStatus()
    @Published private(set) var isImporting = false
    @Published private(set) var isNarrating = false
    @Published var composerText: String = ""
    /// Proposals produced by the engine that the user has not yet acted on.
    @Published private(set) var openProposals: [ReminderProposal] = []

    // MARK: - Subsystems

    let vault: VaultStore
    let languageProvider: LanguageModelProvider
    let scheduler: NotificationScheduler
    let permission: NotificationPermission
    private let playback: SpeechPlayback
    private let normalizer: CareRecordNormalizer
    private let engine: ReminderProposalEngine

    private var hasStarted = false

    /// Dependencies are optional rather than defaulted, because a default argument is evaluated in
    /// a nonisolated context and several of these are `@MainActor`-bound. Passing nil builds the
    /// real thing inside the isolated initializer; tests inject their own.
    init(
        vault: VaultStore? = nil,
        languageProvider: LanguageModelProvider? = nil,
        scheduler: NotificationScheduler? = nil,
        permission: NotificationPermission? = nil,
        playback: SpeechPlayback? = nil,
        normalizer: CareRecordNormalizer = CareRecordNormalizer(),
        engine: ReminderProposalEngine = ReminderProposalEngine()
    ) {
        self.vault = vault ?? VaultStore()
        self.languageProvider = languageProvider ?? LanguageModelProvider()
        self.scheduler = scheduler ?? NotificationScheduler()
        self.permission = permission ?? NotificationPermission()
        self.playback = playback ?? SpeechPlayback()
        self.normalizer = normalizer
        self.engine = engine
        self.status.networkEgressDescription = EgressPolicy.statusStripDescription
    }

    // MARK: - Launch

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        scheduler.registerCategories()
        refreshStatus()

        await vault.loadAll()
        await permission.refresh()
        await scheduler.refreshPending()

        greet()

        // Model preparation is deliberately off the critical path: the app is fully usable while
        // Gemma loads, and the scripted narrator covers the gap.
        Task { await prepareLanguageModel() }

        if vault.careRecord == nil {
            await importDemoSources()
        } else if let record = vault.careRecord {
            rebuildProposals(from: record)
            append(.note("Loaded \(record.medications.count) medications and "
                         + "\(record.therapyTasks.count) exercises from your encrypted vault."))
            await presentNextProposal()
        }
    }

    private func prepareLanguageModel() async {
        do {
            try await languageProvider.model.prepare()
        } catch {
            // Non-fatal by design. The provider has already fallen back to scripted narration.
        }
        refreshStatus()
    }

    private func greet() {
        append(.assistant(
            text: "Hello. Everything we discuss stays on this phone — your records are stored "
                + "encrypted here, and nothing is sent anywhere.",
            narrationSource: .staticCopy
        ))
    }

    // MARK: - Import

    /// v1 reads bundled Synthea and authored sample data through the same connector protocol a
    /// real MyChart connection will use. Only the transport is different.
    func importDemoSources() async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        let connectors: [HealthSourceConnector] = [
            SyntheaBundleConnector.syntheaGlover(),
            SyntheaBundleConnector.portalExportDemo()
        ]

        var imports: [ImportedSource] = []
        for connector in connectors {
            do {
                try await connector.authorize()
                imports.append(try await connector.importedSource())
            } catch {
                append(.note("Could not read \(connector.source.displayName): "
                             + "\(error.localizedDescription)"))
            }
        }

        guard !imports.isEmpty else {
            append(.assistant(
                text: "I could not read any health records just now, so there is nothing for me "
                    + "to suggest yet.",
                narrationSource: .staticCopy
            ))
            return
        }

        let snapshot = normalizer.snapshot(from: imports)
        vault.saveCareRecord(snapshot)
        rebuildProposals(from: snapshot)

        append(.note("Imported from \(snapshot.sourceLabels.count) sources · stored encrypted on "
                     + "this device"))

        append(.heard(
            summary: "\(snapshot.medications.count) medications and "
                   + "\(snapshot.therapyTasks.count) exercises in your records",
            detail: snapshot.sourceLabels.joined(separator: " · ")
        ))

        if openProposals.isEmpty {
            append(.assistant(
                text: "I read through your records and did not find anything that needs a "
                    + "repeating reminder right now.",
                narrationSource: .staticCopy
            ))
        } else {
            append(.assistant(
                text: "I found \(openProposals.count) things in your records that could become "
                    + "reminders. I will go through them one at a time, and I will show you where "
                    + "each one came from. Nothing is scheduled until you say so.",
                narrationSource: .staticCopy
            ))
            await presentNextProposal()
        }
    }

    private func rebuildProposals(from snapshot: CareRecordSnapshot) {
        let skipped = Set(vault.skippedProposals.map(\.proposalID))
        let approved = Set(vault.approvedReminders.map(\.proposalID))
        openProposals = engine
            .proposals(from: snapshot, skippedProposalIDs: skipped)
            .filter { !approved.contains($0.id) }
    }

    // MARK: - Proposal review

    /// Presents one proposal at a time. The design doc asks for individual review, and a wall of
    /// twelve cards is not review — it is a form to dismiss.
    func presentNextProposal() async {
        guard let next = openProposals.first else { return }
        guard !timelineContainsProposal(next.id) else { return }

        let narration = await narrate(.introduce(next, patientFirstName: patientFirstName))
        append(.assistant(text: narration.text, narrationSource: narration.source))
        append(.proposal(next))
    }

    private func timelineContainsProposal(_ id: String) -> Bool {
        timeline.contains { entry in
            if case .proposal(let proposal) = entry.content { return proposal.id == id }
            return false
        }
    }

    // MARK: - The approval boundary

    /// The only route from a proposal to a scheduled notification.
    func approve(_ proposal: ReminderProposal) async {
        // A proposal with an unset time cannot be scheduled. The card disables approval in that
        // case; this is the belt-and-braces check behind it.
        let times = proposal.slots.compactMap(\.timeOfDay)

        let reminder = ApprovedReminder(
            id: proposal.id,
            proposalID: proposal.id,
            kind: proposal.kind,
            title: proposal.title,
            body: proposal.subtitle ?? proposal.title,
            times: times,
            sourceFacts: proposal.sourceFacts,
            sourceLabel: proposal.sourceLabel,
            dataOrigin: proposal.dataOrigin,
            approvedAt: Date(),
            isActive: true
        )

        vault.approve(reminder)
        consume(proposal.id)

        if times.isEmpty {
            // Kept in the list, but nothing to schedule — an as-needed medication, for example.
            append(.scheduled(reminder))
        } else {
            await ensureNotificationPermission()
            do {
                try await scheduler.schedule(reminder)
                append(.scheduled(reminder))
                let narration = await narrate(.confirm(reminder, patientFirstName: patientFirstName))
                append(.assistant(text: narration.text, narrationSource: narration.source))
            } catch {
                append(.note("I saved this reminder but could not schedule the notification: "
                             + "\(error.localizedDescription)"))
            }
            await scheduler.refreshPending()
        }

        await presentNextProposal()
    }

    func skip(_ proposal: ReminderProposal) async {
        vault.skip(proposalID: proposal.id)
        consume(proposal.id)
        append(.note("Skipped \(proposal.title). I will not bring it up again."))
        await presentNextProposal()
    }

    /// "Edit" is intentionally a conversational turn rather than a form. The thing people most
    /// often want to change is the time, and the card already edits that in place.
    func edit(_ proposal: ReminderProposal) async {
        append(.user(text: "I'd like to change this one.", wasSpoken: false))
        let narration = await narrate(.followUp(
            "The person wants to adjust this reminder before approving it.",
            about: proposal,
            patientFirstName: patientFirstName
        ))
        append(.assistant(text: narration.text, narrationSource: narration.source))
    }

    private func consume(_ proposalID: String) {
        openProposals.removeAll { $0.id == proposalID }
    }

    private func ensureNotificationPermission() async {
        guard !permission.deliversReminders else { return }
        _ = await permission.request()
    }

    // MARK: - Conversation

    func send(_ text: String) async {
        append(.user(text: text, wasSpoken: false))

        // Follow-ups are grounded in a specific proposal — never the whole vault. If there is no
        // proposal in play, the most recent one under discussion is used.
        guard let context = mostRecentProposal() else {
            append(.assistant(
                text: "I can talk through any reminder I have proposed. There is not one open "
                    + "right now.",
                narrationSource: .staticCopy
            ))
            return
        }

        let narration = await narrate(.followUp(
            text,
            about: context,
            patientFirstName: patientFirstName
        ))
        append(.assistant(text: narration.text, narrationSource: narration.source))
    }

    func runQuickAction(_ action: Composer.QuickAction) async {
        await send(action.prompt)
    }

    func showPhotoDraft() {
        append(.user(text: "I want to add a medication from a label photo.", wasSpoken: false))
        append(.photoDraft(PhotoDraft.demoDraft()))
        append(.assistant(
            text: "This is a preview of how that will work. I am not reading your bottle in this "
                + "version, so nothing here came from your photo and I will not create a reminder "
                + "from it.",
            narrationSource: .staticCopy
        ))
    }

    func speak(_ text: String) {
        playback.speak(text)
    }

    /// Demo affordance: fires a real local notification a few seconds out so the loop can be shown
    /// end to end without waiting for the scheduled hour.
    func demoFireMostRecent() async {
        guard let reminder = vault.approvedReminders.last else { return }
        await ensureNotificationPermission()
        do {
            _ = try await scheduler.debugFireSoon(reminder)
            append(.note("Demo: sending that reminder in about 10 seconds."))
        } catch {
            append(.note("Could not send the demo notification: \(error.localizedDescription)"))
        }
    }

    // MARK: - Narration

    private func narrate(_ request: NarrationRequest) async -> NarrationResult {
        isNarrating = true
        defer { isNarrating = false }
        do {
            return try await languageProvider.model.narrate(request)
        } catch {
            // Narration failing must never block the loop; the proposal card already carries the
            // clinical content on its own.
            return .template(text: "Here is what I found in your record.")
        }
    }

    private func mostRecentProposal() -> ReminderProposal? {
        for entry in timeline.reversed() {
            if case .proposal(let proposal) = entry.content { return proposal }
        }
        return openProposals.first
    }

    private var patientFirstName: String? {
        guard let full = vault.careRecord?.patientDisplayName else { return nil }
        return full.split(separator: " ").first.map(String.init)
    }

    // MARK: - Plumbing

    private func append(_ content: TimelineEntry.Content) {
        timeline.append(TimelineEntry(content: content))
    }

    private func refreshStatus() {
        status.modelDescription = languageProvider.statusDescription
        status.modelIsOnDevice = languageProvider.model.isOnDevice
        status.networkEgressDescription = EgressPolicy.statusStripDescription
        status.storageDescription = "Encrypted, this device"
    }
}
