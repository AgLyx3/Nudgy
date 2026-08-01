import CryptoKit
import Foundation
import Security

/// Everything that can go wrong between "the user has health data" and "it is safely at rest".
///
/// Each case carries enough detail to diagnose a failure *without* naming the data involved.
/// `name` is a vault filename like `care-record`, never a medication or a patient name — these
/// values end up in error copy on screen and in the local diagnostics list, and neither may leak PHI.
enum VaultError: Error, LocalizedError, Equatable {
    /// A Keychain call failed. The real `OSStatus` is preserved so a failure on a locked device
    /// (`errSecInteractionNotAllowed`) is distinguishable from a genuinely broken keychain.
    case keychain(operation: String, status: OSStatus)
    /// The Keychain returned an item, but not 32 bytes of key material. Treated as fatal rather
    /// than silently regenerated: regenerating would orphan every existing ciphertext.
    case keyMaterialCorrupt(byteCount: Int)
    /// The system RNG could not produce a key.
    case keyGenerationFailed
    /// AES-GCM refused to open the box: wrong key, truncated file, or tampered ciphertext.
    /// Indistinguishable by design — that is what authenticated encryption buys.
    case decryptionFailed(name: String)
    /// Plaintext decrypted cleanly but does not match the expected type. Usually a schema change.
    case decodeFailed(name: String, underlyingDescription: String)
    case encodeFailed(name: String, underlyingDescription: String)
    case fileSystem(operation: String, underlyingDescription: String)

    var errorDescription: String? {
        switch self {
        case .keychain(let operation, let status):
            return "Secure key storage failed during \(operation) (OSStatus \(status))."
        case .keyMaterialCorrupt(let byteCount):
            return "The stored vault key is \(byteCount) bytes, not 32. Refusing to guess."
        case .keyGenerationFailed:
            return "Could not generate a vault key on this device."
        case .decryptionFailed(let name):
            return "The stored file \(name) could not be decrypted."
        case .decodeFailed(let name, let underlying):
            return "The stored file \(name) could not be read: \(underlying)"
        case .encodeFailed(let name, let underlying):
            return "Could not prepare \(name) for storage: \(underlying)"
        case .fileSystem(let operation, let underlying):
            return "Storage error during \(operation): \(underlying)"
        }
    }

    /// True when retrying later is plausible — chiefly "the phone was locked when we tried".
    var mayResolveOnRetry: Bool {
        if case .keychain(_, let status) = self {
            return status == errSecInteractionNotAllowed || status == errSecNotAvailable
        }
        return false
    }
}

/// Owns the single 256-bit key that every byte of health data on this device is encrypted with.
///
/// The accessibility class is the whole privacy argument, so it is stated once, here:
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
///
/// - *WhenUnlocked* means the key is unreadable while the phone is locked, which is what makes
///   `.completeFileProtection` on the ciphertext meaningful rather than decorative.
/// - *ThisDeviceOnly* keeps the key out of the iCloud Keychain **and** out of encrypted iTunes/
///   Finder backups. The vault therefore cannot be restored onto a second device, on purpose. The
///   design doc promises PHI stays on *this* phone; a key that follows the user to a new phone
///   would quietly make that false.
///
/// The consequence is deliberate and worth stating plainly to the user: if the key is lost — device
/// wiped, app deleted, or `destroyKey()` called — the health vault is unrecoverable. That is the
/// tradeoff a local-only product makes, and it is also the strongest erase we can offer.
struct VaultKeyStore {
    /// Keychain generic-password service. Namespaced to the bundle so a future extension or
    /// sibling app cannot collide with it.
    let service: String
    let account: String

    init(service: String = "app.nudgy.Nudgy.vault", account: String = "vault-master-key") {
        self.service = service
        self.account = account
    }

    // MARK: - Reading and creating

    /// Returns the vault key, generating and storing one on first use.
    ///
    /// Idempotent and safe to call from anywhere: a `errSecDuplicateItem` on insert means another
    /// caller won the race, so we simply read back what they wrote rather than overwriting it.
    /// Overwriting would be catastrophic — it would strand every file already on disk.
    func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try existingKey() {
            return existing
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        guard keyData.count == 32 else { throw VaultError.keyGenerationFailed }

        var attributes = baseQuery()
        attributes[kSecValueData as String] = keyData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        // Explicit even though `ThisDeviceOnly` already implies it. This line is the one an
        // auditor greps for when asking "can health data reach iCloud?".
        attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        attributes[kSecAttrLabel as String] = "Nudgy health vault key"
        attributes[kSecAttrDescription as String] = "AES-256 key for the on-device health vault"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return key
        case errSecDuplicateItem:
            // Lost the race. Whoever inserted first owns the ciphertext; adopt their key.
            guard let existing = try existingKey() else {
                throw VaultError.keychain(operation: "add (duplicate, then absent)", status: status)
            }
            return existing
        default:
            throw VaultError.keychain(operation: "add", status: status)
        }
    }

    /// The stored key, or nil when the vault has never been initialized on this device.
    ///
    /// `errSecItemNotFound` is a normal first-launch state, not an error; every other status is.
    func existingKey() throws -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw VaultError.keychain(operation: "copy (non-data result)", status: status)
            }
            guard data.count == 32 else {
                throw VaultError.keyMaterialCorrupt(byteCount: data.count)
            }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        default:
            throw VaultError.keychain(operation: "copy", status: status)
        }
    }

    /// True when a key exists. Used by the UI to say "encrypted, this device" honestly rather than
    /// as a static label.
    func hasKey() -> Bool {
        ((try? existingKey()) ?? nil) != nil
    }

    // MARK: - Destroying

    /// Deletes the key, which is the strongest erase this app can perform.
    ///
    /// Every vault file on disk becomes permanently undecryptable the instant this returns — no
    /// pass over the filesystem is required, and none of the usual "the deleted blocks are still
    /// physically there" caveats apply. `EncryptedVault.wipeAll()` still runs alongside it so the
    /// storage is actually reclaimed, but *this* call is the one that makes the data unreadable.
    ///
    /// Returns false when there was nothing to delete, so a "delete everything" flow can be run
    /// twice without reporting a spurious failure.
    @discardableResult
    func destroyKey() throws -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw VaultError.keychain(operation: "delete", status: status)
        }
    }

    // MARK: - Private

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
