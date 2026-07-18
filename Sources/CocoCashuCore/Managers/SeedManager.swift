//
//  SeedManager.swift
//  CocoCashuSwift
//
//  Created by Ivan C Myrvold on 27/12/2025.
//


import Foundation
import BIP39
import Security

public enum SeedKeychainError: Error, LocalizedError {
    /// The Keychain refused the read for a reason OTHER than "no item" (locked,
    /// interaction not allowed, permission denied…). The seed may still exist —
    /// callers MUST NOT treat this as "no wallet" and generate a new seed.
    case readFailed(OSStatus)
    /// The Keychain refused to store the seed. The wallet must not proceed as if
    /// the seed were persisted.
    case writeFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let s): return "Could not read the wallet seed from the Keychain (status \(s))."
        case .writeFailed(let s): return "Could not save the wallet seed to the Keychain (status \(s))."
        }
    }
}

public final class SeedManager: @unchecked Sendable {
    public static let shared = SeedManager()
    private let service = "com.cococashu.seed"

    private init() {}
    
    // 1. Generate New Mnemonic (12 words)
    public func generateNewMnemonic() throws -> [String] {
        // Generate the entropy ourselves with a CHECKED SecRandomCopyBytes. The
        // BIP39 package's `Mnemonic()` convenience init ignores the RNG status —
        // if it ever failed there, the all-zero buffer would become the publicly
        // known "abandon abandon … about" phrase and every sat would be stealable.
        // This is the single entropy event of the wallet's lifetime; verify it.
        var entropy = [UInt8](repeating: 0, count: 16) // 128 bits → 12 words
        let status = SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy)
        guard status == errSecSuccess else {
            throw SeedKeychainError.writeFailed(status)
        }
        // Belt and braces: an all-zero buffer here means the RNG lied about success.
        guard entropy.contains(where: { $0 != 0 }) else {
            throw SeedKeychainError.writeFailed(errSecUnimplemented)
        }
        let mnemonic = try BIP39.Mnemonic(entropy: entropy)
        return mnemonic.phrase
    }
    
    // 2. Validate Mnemonic
    public func isValid(_ phrase: [String]) -> Bool {
        return (try? BIP39.Mnemonic(phrase: phrase)) != nil
    }
    
    // 3. Get Seed Data (Words -> Binary)
    public func seed(from phrase: [String]) throws -> Data {
        let mnemonic = try BIP39.Mnemonic(phrase: phrase)
        return Data(mnemonic.seed)
    }
    
    // 4. Save to Keychain
    public func saveToKeychain(phrase: [String]) throws {
        let data = try JSONEncoder().encode(phrase)

        // Search by class/service/account ONLY — including accessibility or value
        // here would fail to match an existing item saved under the old defaults,
        // leaving it in place and making the subsequent add fail as a duplicate.
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "master_seed"
        ]

        var addQuery = searchQuery
        addQuery[kSecValueData as String] = data
        // Explicit policy: readable only while unlocked, and never migrated to
        // another device via backup/transfer — the paper recovery phrase is the
        // cross-device path. (Default was WhenUnlocked WITH migration.)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        // Replace any existing item. errSecItemNotFound just means nothing to delete.
        let deleteStatus = SecItemDelete(searchQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw SeedKeychainError.writeFailed(deleteStatus)
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SeedKeychainError.writeFailed(addStatus)
        }
    }
    
    // 5. Delete (used by wallet reset)
    public func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "master_seed"
        ]
        SecItemDelete(query as CFDictionary)
    }

    // 6. Retrieve
    /// Returns the stored phrase, or `nil` ONLY when the Keychain positively
    /// reports no item exists (`errSecItemNotFound`). Any other failure —
    /// keychain locked, interaction not allowed, access denied, or a corrupt
    /// stored value — throws. Treating those as "no wallet" would lead callers
    /// to generate a fresh seed and OVERWRITE the real one, destroying funds.
    public func retrieveFromKeychain() throws -> [String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "master_seed",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let phrase = try? JSONDecoder().decode([String].self, from: data) else {
                // An item exists but is unreadable — fail closed, never overwrite.
                throw SeedKeychainError.readFailed(errSecDecode)
            }
            return phrase
        case errSecItemNotFound:
            return nil
        default:
            throw SeedKeychainError.readFailed(status)
        }
    }
}
