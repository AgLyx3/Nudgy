import Combine
import Foundation
import Security

/// The observable façade the app actually talks to. Nothing above this layer knows that health data
/// is encrypted, or that it lives in files at all.
///
/// Two properties of this type are load-bearing for the product promise:
///
/// - **Partial failure is survivable.** Each vault file is loaded independently. A schema change
///   that breaks `approved-reminders` must not also hide the user's medication list, and neither
///   may crash the app. Failures surface through `lastError` and a visible degraded state; there is
///   no `try!` anywhere in the persistence path.
/// - **Approval is the only write path to notifications.** `approve(_:)` is the sole way an
///   `ApprovedReminder` enters storage, matching the design doc's rule that every reminder is
///   individually approved before anything is scheduled.
@MainActor
final class VaultStore: ObservableObject {
    /// Everything normalized out of the connected sources. Nil until `loadAll()` has run, or when
    /// no source has been connected yet.
    @Published private(set) var careRecord: CareRecordSnapshot?
    /// Reminders the user has approved. The notification scheduler reads from here and nowhere else.
    @Published private(set) var approvedReminders: [ApprovedReminder] = []
    /// Proposals the user declined, so the engine does not re-offer them after every import.
    @Published private(set) var skippedProposals: [SkippedProposal] = []

    /// The most recent persistence failure, surfaced instead of thrown.
    ///
    /// A storage error is a real event the user deserves to see — "I could not save that reminder"
    /// is very different from a reminder silently not existing — but it is never a reason to take
    /// the app down while someone is mid-conversation about their medication.
    @Published private(set) var lastError: VaultError?
    /// True once `loadAll()` has completed, successfully or otherwise. The UI uses this to avoid
    /// rendering an empty state that looks like data loss during the first few hundred milliseconds.
    @Published private(set) var isLoaded = false

    /// `nonisolated` so background work can reach the vault without hopping to the main actor for
    /// a value that is immutable and thread-safe on its own.
    private nonisolated let vault: EncryptedVault
    private nonisolated let keyStore: VaultKeyStore

    init(vault: EncryptedVault = EncryptedVault(), keyStore: VaultKeyStore = VaultKeyStore()) {
        self.vault = vault
        self.keyStore = keyStore
    }

    // MARK: - Loading

    /// Loads all three files. Call once at launch.
    ///
    /// Decryption and JSON decoding happen off the main thread; only the assignment of the results
    /// comes back to it. The payloads are small — a medication list, not a photo library — so this
    /// stays a single awaited round trip rather than a streaming or paginated API.
    func loadAll() async {
        let loaded = await Task.detached(priority: .userInitiated) { [vault] in
            Self.loadEverything(from: vault)
        }.value

        careRecord = loaded.careRecord
        approvedReminders = loaded.approvedReminders
        skippedProposals = loaded.skippedProposals
        lastError = loaded.firstError
        isLoaded = true
    }

    // MARK: - Mutations

    /// Replaces the stored care record after an import or a manual entry.
    func saveCareRecord(_ snapshot: CareRecordSnapshot) {
        careRecord = snapshot
        persist(snapshot, to: VaultFile.careRecord)
    }

    /// Records the user's approval of a single proposal.
    ///
    /// Re-approving an existing reminder replaces it rather than duplicating, so an edit-then-
    /// approve loop cannot leave two notification sets fighting over the same medication.
    func approve(_ reminder: ApprovedReminder) {
        if let index = approvedReminders.firstIndex(where: { $0.id == reminder.id }) {
            approvedReminders[index] = reminder
        } else {
            approvedReminders.append(reminder)
        }
        // Approving something the user previously skipped should clear the skip, otherwise the
        // record disagrees with itself.
        skippedProposals.removeAll { $0.proposalID == reminder.proposalID }
        persist(approvedReminders, to: VaultFile.approvedReminders)
        persist(skippedProposals, to: VaultFile.skippedProposals)
    }

    /// Removes an approved reminder. The caller is responsible for cancelling its notifications;
    /// this layer deliberately knows nothing about `UNUserNotificationCenter`.
    func removeReminder(id: String) {
        let before = approvedReminders.count
        approvedReminders.removeAll { $0.id == id }
        guard approvedReminders.count != before else { return }
        persist(approvedReminders, to: VaultFile.approvedReminders)
    }

    /// Marks a proposal as skipped. Idempotent: skipping twice does not accumulate entries.
    func skip(proposalID: String) {
        guard !skippedProposals.contains(where: { $0.proposalID == proposalID }) else { return }
        skippedProposals.append(
            SkippedProposal(id: UUID().uuidString, proposalID: proposalID, skippedAt: Date())
        )
        persist(skippedProposals, to: VaultFile.skippedProposals)
    }

    /// True when the user has already declined this proposal.
    func isSkipped(proposalID: String) -> Bool {
        skippedProposals.contains { $0.proposalID == proposalID }
    }

    /// The reminder derived from a given proposal, if the user approved one.
    func approvedReminder(forProposalID proposalID: String) -> ApprovedReminder? {
        approvedReminders.first { $0.proposalID == proposalID }
    }

    // MARK: - Erasure

    /// The "delete everything" affordance.
    ///
    /// Order matters. Files are removed first so the space is reclaimed, then the key is destroyed —
    /// and the key is what actually makes any surviving bytes unreadable forever. Doing it the other
    /// way round would still be safe, but this order means a failure partway through leaves *less*
    /// recoverable data, not more.
    ///
    /// In-memory state is cleared unconditionally, even if the filesystem call failed, because a UI
    /// still showing medications after the user pressed "delete everything" is its own kind of
    /// broken promise.
    func wipeEverything() async {
        let failure = await Task.detached(priority: .userInitiated) { [vault, keyStore] () -> VaultError? in
            var firstError: VaultError?
            do {
                try vault.wipeAll()
            } catch let error as VaultError {
                firstError = error
            } catch {
                firstError = .fileSystem(operation: "wipe vault", underlyingDescription: String(describing: error))
            }
            do {
                try keyStore.destroyKey()
            } catch let error as VaultError {
                firstError = firstError ?? error
            } catch {
                firstError = firstError ?? .keychain(operation: "delete", status: errSecInternalError)
            }
            vault.forgetCachedKey()
            return firstError
        }.value

        careRecord = nil
        approvedReminders = []
        skippedProposals = []
        lastError = failure
    }

    /// Dismisses a surfaced error after the user has seen it.
    func clearLastError() { lastError = nil }

    // MARK: - Private

    /// Fire-and-forget encrypted write. The in-memory value has already been updated, so the UI is
    /// responsive immediately and a storage failure arrives as `lastError` a moment later.
    private func persist<T: Encodable>(_ value: T, to name: String) {
        Task.detached(priority: .utility) { [vault] in
            do {
                try vault.write(value, to: name)
            } catch let error as VaultError {
                await self.record(error)
            } catch {
                await self.record(
                    .fileSystem(operation: "write \(name)", underlyingDescription: String(describing: error))
                )
            }
        }
    }

    private func record(_ error: VaultError) {
        lastError = error
    }

    /// Result of a load pass. Each field is independent by construction — that is the whole point.
    private struct LoadedState {
        var careRecord: CareRecordSnapshot?
        var approvedReminders: [ApprovedReminder] = []
        var skippedProposals: [SkippedProposal] = []
        var firstError: VaultError?
    }

    /// `nonisolated` and `static` so it can run on a background executor without capturing self.
    private nonisolated static func loadEverything(from vault: EncryptedVault) -> LoadedState {
        var state = LoadedState()

        // Each read is independently guarded. A corrupt reminder list must not hide the care
        // record, and vice versa.
        state.careRecord = attempt(&state.firstError) {
            try vault.read(CareRecordSnapshot.self, from: VaultFile.careRecord)
        } ?? nil

        state.approvedReminders = (attempt(&state.firstError) {
            try vault.read([ApprovedReminder].self, from: VaultFile.approvedReminders)
        } ?? nil) ?? []

        state.skippedProposals = (attempt(&state.firstError) {
            try vault.read([SkippedProposal].self, from: VaultFile.skippedProposals)
        } ?? nil) ?? []

        return state
    }

    /// Runs one read, recording the first failure and returning nil instead of propagating it.
    private nonisolated static func attempt<T>(
        _ firstError: inout VaultError?,
        _ work: () throws -> T
    ) -> T? {
        do {
            return try work()
        } catch let error as VaultError {
            if firstError == nil { firstError = error }
            return nil
        } catch {
            if firstError == nil {
                firstError = .fileSystem(operation: "load", underlyingDescription: String(describing: error))
            }
            return nil
        }
    }
}
