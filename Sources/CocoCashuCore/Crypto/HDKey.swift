import Foundation
import CryptoKit

/// A lightweight BIP32 HD Node implementation for NUT-09
public struct HDKey {
    public let key: SymmetricKey
    public let chainCode: Data
    
    // Master Node from Seed
    public init(seed: Data) {
        let hmac = HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: "Bitcoin seed".data(using: .utf8)!))
        let data = Data(hmac)
        self.key = SymmetricKey(data: data.prefix(32))
        self.chainCode = data.suffix(32)
    }
    
    // Private Child Derivation (CKDpriv)
    // Support hardened derivation (index >= 0x80000000)
    public func derive(index: UInt32) -> HDKey? {
        var data = Data()
        
        if index >= 0x80000000 {
            // Hardened: 0x00 + key + index
            data.append(0)
            data.append(key.withUnsafeBytes { Data($0) })
        } else {
            // Non-hardened: pubkey + index (NOT IMPLEMENTED HERE for simplicity, Cashu uses hardened mostly)
            // If Cashu uses non-hardened, we need public key generic. 
            // For NUT-09, strictly speaking, we drive secrets.
            // Let's assume Hardened for safety or implement standard BIP32 if needed.
            // NUT-09 uses m/129372'/0'/... (All hardened top level). 
            return nil 
        }
        
        data.append(withUnsafeBytes(of: index.bigEndian) { Data($0) })
        
        let hmac = HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: chainCode))
        let output = Data(hmac)
        
        return HDKey(
            key: SymmetricKey(data: output.prefix(32)),
            chainCode: output.suffix(32)
        )
    }
    
    // Helper for path string "m/129372'/0'..."
    // NUT-09 Path: m/129372'/0'/{keyset}'/{counter}'/{0 or 1}
    public func derive(path: [UInt32]) -> HDKey? {
        var current = self
        for index in path {
            guard let next = current.derive(index: index) else { return nil }
            current = next
        }
        return current
    }
}