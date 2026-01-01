import Foundation
import BIP39
import Security

public final class SeedManager {
    public static let shared = SeedManager()
    private let service = "com.cococashu.seed"
    
    private init() {}
    
    // 1. Generate New Mnemonic (12 words)
    public func generateNewMnemonic() throws -> [String] {
        let mnemonic = try BIP39.Mnemonic()
        return mnemonic.mnemonic()
    }
    
    // 2. Validate Mnemonic
    public func isValid(_ phrase: [String]) -> Bool {
        return (try? BIP39.Mnemonic(mnemonic: phrase)) != nil
    }
    
    // 3. Get Seed Data (Words -> Binary)
    public func seed(from phrase: [String]) throws -> Data {
        let mnemonic = try BIP39.Mnemonic(mnemonic: phrase)
        return mnemonic.seed() // Returns 64 bytes
    }
    
    // 4. Save to Keychain
    public func saveToKeychain(phrase: [String]) throws {
        let data = try JSONEncoder().encode(phrase)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "master_seed",
            kSecValueData as String: data
        ]
        
        // Delete old if exists
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    // 5. Retrieve
    public func retrieveFromKeychain() -> [String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "master_seed",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}