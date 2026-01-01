import Foundation
import CryptoKit

public actor CocoBlindingEngine: BlindingEngine {
    private let seed: Data
    private let masterKey: HDKey
    
    public init(seed: Data) {
        self.seed = seed
        self.masterKey = HDKey(seed: seed)
    }
    
    // Store active counters in memory (In real app, persist these!)
    private var counters: [String: UInt32] = [:]
    
    public func getBlindingFactors(keysetId: String, amount: Int, count: Int) async throws -> [PreCalculated] {
        // 1. Convert KeysetID (Hex) to Int (Hash modulation per spec)
        // Note: Real NUT-09 requires integer reduction of keysetID.
        // For simplicity, we assume we map keysetId -> some Int index, or hash it.
        // A common simplification is using the first 4 bytes of the keyset ID.
        let keysetInt = try keysetIdToInt(keysetId)
        
        var outputs: [PreCalculated] = []
        
        // 2. Get current counter
        let startCounter = counters[keysetId] ?? 0
        
        for i in 0..<count {
            let currentCounter = startCounter + UInt32(i)
            
            // Path: m / 129372' / 0' / keyset' / counter'
            // 129372 is 'NUT' on phone keypad
            let basePath = [
                UInt32(129372) + 0x80000000,
                UInt32(0) + 0x80000000,
                keysetInt + 0x80000000,
                currentCounter + 0x80000000
            ]
            
            guard let baseNode = masterKey.derive(path: basePath) else { continue }
            
            // Derive Secret (0) and r (1) - Not hardened at the leaf
            // Wait, our HDKey is hardened only. Cashu spec actually usually implies 
            // derived keys are just bytes.
            // Let's simply HMAC the baseNode key with "0" and "1".
            
            let k = baseNode.key
            let secretBytes = HMAC<SHA256>.authenticationCode(for: Data([0]), using: k)
            let rBytes = HMAC<SHA256>.authenticationCode(for: Data([1]), using: k)
            
            let secretStr = Data(secretBytes).map { String(format: "%02x", $0) }.joined()
            let rKey = PrivateKey(data: Data(rBytes)) // Assuming you have a PrivateKey struct wrapper
            
            outputs.append(PreCalculated(secret: secretStr, r: rKey, amount: Int64(amount)))
        }
        
        // Update counter
        counters[keysetId] = startCounter + UInt32(count)
        
        return outputs
    }
    
    // Helper to turn Keyset ID string into UInt32
    private func keysetIdToInt(_ id: String) throws -> UInt32 {
        // Take first 4 bytes of hex string
        // This is a simplification. NUT-09 usually specifies strict mapping.
        let data = Data(hex: id).prefix(4)
        guard data.count == 4 else { return 0 }
        return data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }
}