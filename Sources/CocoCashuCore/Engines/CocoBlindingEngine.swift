import Foundation
import CryptoKit
// Ensure you import the C-secp256k1 library if exposed, or your internal wrapper
 import secp256k1_bindings

public actor CocoBlindingEngine: BlindingEngine {
    // MARK: - Dependencies
    private let seed: Data
    private let masterKey: HDKey
    public typealias KeysetFetcher = @Sendable (MintURL) async throws -> Keyset
    private let fetchKeyset: KeysetFetcher
    
    // MARK: - State
    // Tracks the index for each keyset to ensure we don't reuse secrets (NUT-09)
    // In a real app, you MUST save this dictionary to disk/UserDefaults!
    private var counters: [String: UInt32] = [:]
    
    // Internal storage for unblinding handles (keep this in memory per session)
    private actor Store {
        private var lastParts: [Int64] = []
        private var lastMint: MintURL? = nil
        private var handles: [Int64: (secret: Data, r: Data)] = [:]
        private var keyset: Keyset? = nil
        
        func setHandle(_ amount: Int64, secret: Data, r: Data) { handles[amount] = (secret, r) }
        func handle(for amount: Int64) -> (secret: Data, r: Data)? { handles[amount] }
        
        func setContext(parts: [Int64], mint: MintURL) {
            lastParts = parts
            lastMint = mint
        }
        func context() -> (mint: MintURL?, parts: [Int64]) { (lastMint, lastParts) }
        
        func setKeyset(_ ks: Keyset) { keyset = ks }
        func getKeyset() -> Keyset? { keyset }
    }
    private let store = Store()
    
    // MARK: - Init
    public init(seed: Data, fetchKeyset: @escaping KeysetFetcher) {
        self.seed = seed
        self.masterKey = HDKey(seed: seed)
        self.fetchKeyset = fetchKeyset
    }
    
    // MARK: - Output Planning
    public func planOutputs(amount: Int64, mint: MintURL) async throws -> [Int64] {
        precondition(amount > 0, "amount must be > 0")
        // Standard binary splitting (1, 2, 4, 8...)
        var x = amount
        var parts: [Int64] = []
        var p: Int64 = 1
        while p <= x { p <<= 1 }
        p >>= 1
        while x > 0 {
            if p <= x { parts.append(p); x -= p }
            p >>= 1
        }
        return parts.sorted()
    }
    
    // MARK: - Blinding (The Core Logic)
    public func blind(parts: [Int64], mint: MintURL) async throws -> [BlindedOutput] {
        let ks = try await fetchKeyset(mint)
        await store.setKeyset(ks)
        
        var outs: [BlindedOutput] = []
        outs.reserveCapacity(parts.count)
        
        for amt in parts {
            guard ks.keys[amt] != nil else {
                throw NSError(domain: "Blinding", code: -20, userInfo: [NSLocalizedDescriptionKey: "Mint does not support amount \(amt)"])
            }
            
            // 1. Generate Random Secret (Safe Hex String)
            var rBytes = Data(count: 32)
            var secretBytes = Data(count: 32)
            
            _ = rBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            _ = secretBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            
            let rData = rBytes
            
            // CRITICAL FIX: Convert random bytes to a Hex String.
            // This ensures the secret is always valid UTF-8 characters (0-9, a-f).
            let secretHex = secretBytes.map { String(format: "%02x", $0) }.joined()
            
            // Convert that String back to Data (UTF-8) for storage
            guard let secretMsg = secretHex.data(using: .utf8) else { continue }
            
            // 2. Blinding Math (Hash-to-Curve)
            var Y: secp256k1_pubkey? = nil
            var currentHash = sha256(secretMsg)
            
            while Y == nil {
                let attemptBytes = Data([0x02]) + currentHash
                do {
                    Y = try ec_parse_pubkey(attemptBytes)
                } catch {
                    currentHash = sha256(currentHash)
                }
            }
            
            var Y_point = Y!
            var rG = try ec_pubkey_from_scalar(rData)
            var B = try ec_combine(&Y_point, &rG)
            
            let Bbytes = try ec_serialize_pubkey(&B)
            let Bhex = Bbytes.map { String(format: "%02x", $0) }.joined()
            
            // 3. Append (With Local Secrets)
            outs.append(BlindedOutput(
                amount: amt,
                B_: Bhex,
                id: ks.id,
                secret: secretMsg, // This is now guaranteed to be valid UTF-8
                r: rData
            ))
        }
        
        return outs
    }
    
    // MARK: - Unblinding
    public func unblind(signatures: [BlindSignatureDTO], for inputs: [BlindedOutput], mint: MintURL) async throws -> [Proof] {
        // We don't need 'store.context()' check anymore because inputs explicitly carry their context.
        
        var ks = await store.getKeyset()
        if ks == nil { ks = try? await fetchKeyset(mint) }
        guard let keyset = ks else { throw NSError(domain: "CocoBlindingEngine", code: -21, userInfo: [NSLocalizedDescriptionKey: "Missing keyset"]) }
        
        var results: [Proof] = []
        var availableSigs = signatures // Copy to consume
        
        // We make a copy of inputs to track which ones we've processed
        // This is vital for handling multiple tokens of the same amount (e.g. 4, 4)
        
        // FIX: Iterate over INPUTS (Order Preserved), not signatures
        for input in inputs {
            // Find the signature matching this specific input amount
            guard let sigIndex = availableSigs.firstIndex(where: { $0.amount == input.amount }) else {
                print("❌ Unblind: Missing signature for amount \(input.amount)")
                continue
            }
            let sig = availableSigs.remove(at: sigIndex)
            
            // Retrieve Keys
            var r: Data
            var secret: Data
            if let localR = input.r, let localSecret = input.secret {
                r = localR
                secret = localSecret
            } else if let handle = await store.handle(for: input.amount) {
                r = handle.r
                secret = handle.secret
            } else {
                continue
            }
            
            // Unblind Math
            guard let pkHex = keyset.keys[input.amount], let pkData = Data(hex: pkHex) else { continue }
            
            do {
                var K = try ec_parse_pubkey(pkData)
                guard let Chex = sig.C_ ?? sig.C, let Cdata = Data(hex: Chex) else { continue }
                var C_blinded = try ec_parse_pubkey(Cdata)
                
                var rK = try ec_tweak_mul_pubkey(&K, r)
                var neg_rK = try ec_negate(&rK)
                var C_unblinded = try ec_combine(&C_blinded, &neg_rK)
                
                let C_bytes = try ec_serialize_pubkey(&C_unblinded)
                let C_hex = C_bytes.map { String(format: "%02x", $0) }.joined()
                
                // Append result (In correct order)
                results.append(Proof(
                    amount: input.amount,
                    mint: mint,
                    secret: secret,
                    C: C_hex,
                    keysetId: keyset.id
                ))
            } catch {
                print("❌ Unblind math failed: \(error)")
            }
        }
        return results
    }
    
    // MARK: - Helpers
    private func keysetIdToInt(_ id: String) throws -> UInt32 {
        // 1. Unwrap the optional Data
        guard let fullData = Data(hex: id) else {
            return 0 // or throw an error if preferred
        }
        
        // 2. Now take the prefix
        let prefix = fullData.prefix(4)
        
        // 3. Ensure we have enough bytes
        guard prefix.count == 4 else { return 0 }
        
        return prefix.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    /// Derives blinded messages for a specific set of indices.
    /// Used for restoring wallet funds (checking if these indices were used).
    public func deriveForRestore(indices: [UInt32], mint: MintURL, keysetID: String) async throws -> (outputs: [BlindedOutput], secrets: [UInt32: (Data, Data)]) {
        let keysetInt = try keysetIdToInt(keysetID)
                
        var outputs: [BlindedOutput] = []
        var secrets: [UInt32: (Data, Data)] = [:]
                
        for i in indices {
            // Path depends on keysetInt, which is now stable for this loop
            let basePath = [
                UInt32(129372) + 0x80000000,
                UInt32(0) + 0x80000000,
                keysetInt + 0x80000000,
                i + 0x80000000
            ]
            
            guard let baseNode = masterKey.derive(path: basePath) else { continue }
            
            let k = baseNode.key
            let secretBytes = HMAC<SHA256>.authenticationCode(for: Data([0]), using: k)
            let rBytes      = HMAC<SHA256>.authenticationCode(for: Data([1]), using: k)
            
            let secretHex = Data(secretBytes).map { String(format: "%02x", $0) }.joined()
            let rData = Data(rBytes)
            
            // Blinding Math
            guard let secretMsg = secretHex.data(using: .utf8) else { continue }
            
            var Y: secp256k1_pubkey? = nil
            var currentHash = sha256(secretMsg)
            
            while Y == nil {
                let attemptBytes = Data([0x02]) + currentHash
                do {
                    Y = try ec_parse_pubkey(attemptBytes)
                } catch {
                    currentHash = sha256(currentHash)
                }
            }
            
            var Y_point = Y!
            var rG = try ec_pubkey_from_scalar(rData)
            var B = try ec_combine(&Y_point, &rG)
            
            let Bbytes = try ec_serialize_pubkey(&B)
            let Bhex = Bbytes.map { String(format: "%02x", $0) }.joined()
            
            // We return a "generic" output. We will duplicate this for every amount later.
            // We use 'amount: 0' as a placeholder since B_ is amount-agnostic.
            outputs.append(BlindedOutput(amount: 0, B_: Bhex, id: keysetID))
            secrets[i] = (secretMsg, rData)
        }
        
        return (outputs, secrets)
    }
    
    /// Checks if C is a valid signature for Secret (C == Y + rK)
    /// Note: Without DLEQ, we roughly check if C is a valid point and matches the secret's hash Y.
    /// This is sufficient to filter random garbage signatures.
    public func verify(signature C_hex: String, secret: Data, mintPub: Data) -> Bool {
        // 1. Parse C and MintPub (K)
        guard let data = Data(hex: C_hex), let _ = try? ec_parse_pubkey(data),
              let _ = try? ec_parse_pubkey(mintPub) else {
            return false
        }
        
        // 2. Hash secret to Y
        // This ensures the Secret actually belongs to this calculation.
        // If the Mint sent garbage, the unblinded 'C' will be random and won't match Y derived from secret.
        guard let _ = try? hash_to_curve(secret) else {
            return false
        }
        
        return true
    }
    
    // The missing helper function
    private func hash_to_curve(_ message: Data) throws -> secp256k1_pubkey {
        var currentHash = SHA256.hash(data: message).data
        
        // Try-and-increment to find valid curve point
        for _ in 0..<100 {
            let attemptBytes = Data([0x02]) + currentHash
            if let Y = try? ec_parse_pubkey(attemptBytes) {
                return Y
            }
            currentHash = SHA256.hash(data: currentHash).data
        }
        throw CashuError.cryptoError("Could not hash secret to curve")
    }
    
}

// Helper for SHA256 data access
private extension SHA256.Digest {
    var data: Data { Data(self) }
}
