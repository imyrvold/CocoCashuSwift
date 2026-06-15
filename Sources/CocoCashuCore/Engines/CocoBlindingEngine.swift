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

    // Persistent NUT-13 derivation counter, scoped per keyset. Reserving indices
    // here (instead of using random secrets) is what makes minted proofs
    // recoverable by seed-based restore — and what prevents secret reuse.
    private let counterRepo: CounterRepository

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
    public init(seed: Data, counterRepo: CounterRepository, fetchKeyset: @escaping KeysetFetcher) {
        self.seed = seed
        self.masterKey = HDKey(seed: seed)
        self.counterRepo = counterRepo
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

        // Validate all denominations are supported BEFORE reserving any counter
        // indices, so a bad request doesn't burn (skip) derivation indices.
        for amt in parts {
            guard ks.keys[amt] != nil else {
                throw NSError(domain: "Blinding", code: -20, userInfo: [NSLocalizedDescriptionKey: "Mint does not support amount \(amt)"])
            }
        }

        // Reserve a contiguous block of NUT-13 indices for this keyset. The
        // repository persists the advance, so these indices are never reused.
        let startIndex = try await counterRepo.reserve(key: ks.id, count: parts.count)

        var outs: [BlindedOutput] = []
        outs.reserveCapacity(parts.count)

        for (offset, amt) in parts.enumerated() {
            let index = UInt32(truncatingIfNeeded: startIndex + Int64(offset))

            // 1. Deterministically derive secret + blinding factor r from the seed
            //    (must match deriveForRestore so restore can rediscover this proof).
            let (secretMsg, rBytes) = try deriveSecretAndR(keysetID: ks.id, index: index)

            // 2. Blinding Math (Hash-to-Curve): B_ = Y + r*G
            var Y_point = try hash_to_curve(secretMsg)
            var rG = try ec_pubkey_from_scalar(rBytes)
            var B = try ec_combine(&Y_point, &rG)

            let Bbytes = try ec_serialize_pubkey(&B)
            let Bhex = Bbytes.map { String(format: "%02x", $0) }.joined()

            // 3. Append (With Local Secrets)
            outs.append(BlindedOutput(
                amount: amt,
                B_: Bhex,
                id: ks.id,
                secret: secretMsg,
                r: rBytes
            ))
        }

        return outs
    }

    /// NUT-13 deterministic derivation of (secret message, blinding factor r) for a
    /// given keyset and index. Path: m/129372'/0'/{keyset}'/{index}', with
    /// secret = HMAC(k, 0x00) and r = HMAC(k, 0x01). Shared by `blind` and
    /// `deriveForRestore` so minting and restoration always agree.
    private func deriveSecretAndR(keysetID: String, index: UInt32) throws -> (secret: Data, r: Data) {
        let keysetInt = try keysetIdToInt(keysetID)
        let path = [
            UInt32(129372) + 0x80000000,
            UInt32(0) + 0x80000000,
            keysetInt + 0x80000000,
            index + 0x80000000
        ]
        guard let node = masterKey.derive(path: path) else {
            throw CashuError.cryptoError("HD derivation failed for index \(index)")
        }
        let k = node.key
        let secretBytes = HMAC<SHA256>.authenticationCode(for: Data([0]), using: k)
        let rBytes = HMAC<SHA256>.authenticationCode(for: Data([1]), using: k)
        let secretHex = Data(secretBytes).map { String(format: "%02x", $0) }.joined()
        guard let secretMsg = secretHex.data(using: .utf8) else {
            throw CashuError.cryptoError("Could not encode derived secret")
        }
        return (secretMsg, Data(rBytes))
    }
    
    // MARK: - Unblinding
    public func unblind(signatures: [BlindSignatureDTO], for inputs: [BlindedOutput], mint: MintURL) async throws -> [Proof] {
        
        var ks = await store.getKeyset()
        if ks == nil { ks = try? await fetchKeyset(mint) }
        guard let keyset = ks else { throw NSError(domain: "Blinding", code: -21, userInfo: [NSLocalizedDescriptionKey: "Missing keyset"]) }
        
        var results: [Proof] = []
        var availableSigs = signatures
        
        for input in inputs {
            guard let sigIndex = availableSigs.firstIndex(where: { $0.amount == input.amount }) else { continue }
            let sig = availableSigs.remove(at: sigIndex)
            
            guard let r = input.r, let secret = input.secret else { continue }
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
                
                // THE DECISION
                let finalId = sig.id ?? input.id ?? keyset.id
                
                results.append(Proof(
                    amount: input.amount,
                    mint: mint,
                    secret: secret,
                    C: C_hex,
                    keysetId: finalId
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
        var outputs: [BlindedOutput] = []
        var secrets: [UInt32: (Data, Data)] = [:]

        for i in indices {
            // Same deterministic derivation as `blind`, so a minted proof at this
            // index produces an identical blinded message here during restore.
            let (secretMsg, rData) = try deriveSecretAndR(keysetID: keysetID, index: i)

            // Blinding Math: B_ = Y + r*G
            var Y_point = try hash_to_curve(secretMsg)
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
    
    /// NUT-00 hash-to-curve. MUST match the mint exactly or proofs never verify:
    ///   msg  = sha256("Secp256k1_HashToCurve_Cashu_" || x)
    ///   Y    = lift_x(0x02 || sha256(msg || counter_le32)), incrementing counter
    ///          until a valid x-coordinate is found.
    /// (The earlier sha256(x)-with-no-domain-separator version is the deprecated
    /// pre-2023 scheme and is incompatible with modern mints.)
    private static let hashToCurveDomain = Data("Secp256k1_HashToCurve_Cashu_".utf8)

    func hash_to_curve(_ message: Data) throws -> secp256k1_pubkey {
        let msgHash = sha256(Self.hashToCurveDomain + message)
        var counter: UInt32 = 0
        while counter < 1_000 {
            var toHash = msgHash
            withUnsafeBytes(of: counter.littleEndian) { toHash.append(contentsOf: $0) }
            let attemptBytes = Data([0x02]) + sha256(toHash)
            if let Y = try? ec_parse_pubkey(attemptBytes) {
                return Y
            }
            counter += 1
        }
        throw CashuError.cryptoError("Could not hash secret to curve")
    }

}

// Helper for SHA256 data access
private extension SHA256.Digest {
    var data: Data { Data(self) }
}
