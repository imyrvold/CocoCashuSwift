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

    // Internal storage for unblinding handles (keep this in memory per session).
    // Keysets are cached PER MINT: a single global slot meant interleaved flows
    // against two mints could unblind against the wrong mint's public keys —
    // producing invalid proofs after the inputs were already spent.
    private actor Store {
        private var keysets: [String: Keyset] = [:]

        func setKeyset(_ ks: Keyset, for mint: MintURL) { keysets[mint.absoluteString] = ks }
        func getKeyset(for mint: MintURL) -> Keyset? { keysets[mint.absoluteString] }
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
        await store.setKeyset(ks, for: mint)

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
    /// given keyset and index, following the spec exactly so that seed phrases are
    /// portable across Cashu wallets (Minibits, cashu.me, cdk, ...):
    ///
    /// Version `00` keysets (8-byte hex IDs) — BIP32:
    ///   secret = privkey( m/129372'/0'/{keyset_id_int}'/{counter}'/0 ).hex  (UTF-8)
    ///   r      = privkey( m/129372'/0'/{keyset_id_int}'/{counter}'/1 )
    ///   (final step NON-hardened; keyset_id_int = int(id_bytes) % (2^31 − 1))
    ///
    /// Version `01` keysets (33-byte IDs) — HMAC-SHA256 KDF keyed with the seed:
    ///   message = "Cashu_KDF_HMAC_SHA256" || id_bytes || counter_u64_be || type
    ///   secret  = HMAC(seed, message‖0x00).hex (UTF-8),  r = HMAC(seed, message‖0x01) mod n
    ///
    /// Shared by `blind` and `deriveForRestore` so minting and restore always agree.
    private func deriveSecretAndR(keysetID: String, index: UInt32) throws -> (secret: Data, r: Data) {
        // H6: any keyset ID we can't parse MUST throw. The old code returned 0,
        // silently collapsing every unparseable keyset into one derivation branch —
        // identical secrets across keysets/mints (linkability + duplicate proofs).
        guard let keysetBytes = Data(hex: keysetID) else {
            throw CashuError.cryptoError("Unsupported keyset ID '\(keysetID)' — not hex; refusing to derive NUT-13 secrets")
        }

        if keysetBytes.count == 8, keysetID.lowercased().hasPrefix("00") {
            return try deriveV00(keysetBytes: keysetBytes, index: index)
        } else if keysetBytes.count == 33, keysetID.lowercased().hasPrefix("01") {
            return try deriveV01(keysetBytes: keysetBytes, index: index)
        } else {
            throw CashuError.cryptoError("Unsupported keyset ID version/length for '\(keysetID)'")
        }
    }

    /// Legacy (version 00) BIP32 derivation.
    private func deriveV00(keysetBytes: Data, index: UInt32) throws -> (secret: Data, r: Data) {
        // keyset_id_int = int.from_bytes(id_bytes, "big") % (2^31 - 1)
        let intValue = keysetBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let keysetInt = UInt32(intValue % ((1 << 31) - 1))

        let basePath: [UInt32] = [
            129372 | 0x80000000,
            0 | 0x80000000,
            keysetInt | 0x80000000,
            index | 0x80000000
        ]
        guard let secretNode = masterKey.derive(path: basePath + [0]),   // non-hardened
              let rNode = masterKey.derive(path: basePath + [1]) else {  // non-hardened
            throw CashuError.cryptoError("HD derivation failed for index \(index)")
        }
        let secretHex = secretNode.privateKey.hexString
        guard let secretMsg = secretHex.data(using: .utf8) else {
            throw CashuError.cryptoError("Could not encode derived secret")
        }
        return (secretMsg, rNode.privateKey)
    }

    /// Version 01 HMAC-SHA256 KDF derivation.
    private func deriveV01(keysetBytes: Data, index: UInt32) throws -> (secret: Data, r: Data) {
        var message = Data("Cashu_KDF_HMAC_SHA256".utf8)
        message.append(keysetBytes)
        withUnsafeBytes(of: UInt64(index).bigEndian) { message.append(contentsOf: $0) }

        let key = SymmetricKey(data: seed)
        let secretDigest = Data(HMAC<SHA256>.authenticationCode(for: message + Data([0x00]), using: key))
        let rDigest = Data(HMAC<SHA256>.authenticationCode(for: message + Data([0x01]), using: key))

        guard let secretMsg = secretDigest.hexString.data(using: .utf8) else {
            throw CashuError.cryptoError("Could not encode derived secret")
        }
        let r = try Self.reduceScalarModN(rDigest)
        return (secretMsg, r)
    }

    /// secp256k1 group order n.
    private static let curveOrderN: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41
    ]

    /// Reduce a 32-byte big-endian value mod n. Any 256-bit value is < 2n (n is
    /// just below 2^256), so a single conditional subtraction suffices.
    static func reduceScalarModN(_ value: Data) throws -> Data {
        guard value.count == 32 else { throw CashuError.cryptoError("Scalar must be 32 bytes") }
        if ec_seckey_verify(value) { return value }
        // value ≥ n (or zero): subtract n once with borrow arithmetic.
        var bytes = [UInt8](value)
        var borrow = 0
        for i in stride(from: 31, through: 0, by: -1) {
            let diff = Int(bytes[i]) - Int(curveOrderN[i]) - borrow
            bytes[i] = UInt8((diff + 256) % 256)
            borrow = diff < 0 ? 1 : 0
        }
        let reduced = Data(bytes)
        guard borrow == 0, ec_seckey_verify(reduced) else {
            throw CashuError.cryptoError("Derived blinding factor reduced to an invalid scalar")
        }
        return reduced
    }
    
    // MARK: - Unblinding
    public func unblind(signatures: [BlindSignatureDTO], for inputs: [BlindedOutput], mint: MintURL) async throws -> [Proof] {

        var ks = await store.getKeyset(for: mint)
        if ks == nil { ks = try? await fetchKeyset(mint) }
        guard let keyset = ks else { throw NSError(domain: "Blinding", code: -21, userInfo: [NSLocalizedDescriptionKey: "Missing keyset"]) }

        // Pair signatures to inputs strictly BY INDEX: the protocol requires the
        // mint to return signatures in request order, and outputs routinely contain
        // duplicate denominations (token + change splits), so matching by amount
        // could unblind sig A with blinding factor B — corrupting both proofs after
        // the inputs are already spent. The mint may return FEWER signatures than
        // outputs (melt change consumed by a fee spike): the returned prefix still
        // corresponds positionally. The signature's amount is authoritative — for
        // melt change the mint assigns denominations to our blinded points, and its
        // signing key is the one for THAT amount.
        guard signatures.count <= inputs.count else {
            throw CashuError.protocolError("Mint returned more signatures (\(signatures.count)) than outputs sent (\(inputs.count))")
        }

        var results: [Proof] = []

        for (index, sig) in signatures.enumerated() {
            let input = inputs[index]
            // Reject non-positive amounts from the mint response before they reach
            // balance math (a negative amount would make sums and fee arithmetic go
            // wrong, and `keyset.keys` has no key for it anyway).
            guard sig.amount > 0 else { continue }
            guard let r = input.r, let secret = input.secret else { continue }
            guard let pkHex = keyset.keys[sig.amount], let pkData = Data(hex: pkHex) else { continue }

            do {
                var K = try ec_parse_pubkey(pkData)
                guard let Chex = sig.C_ ?? sig.C, let Cdata = Data(hex: Chex) else { continue }
                var C_blinded = try ec_parse_pubkey(Cdata)

                // NUT-12: if the mint included a DLEQ proof, it MUST verify. A
                // present-but-invalid proof means the mint did not sign with its
                // published key — it may be tagging us with a per-user key or
                // returning garbage — so we drop the signature instead of minting an
                // unverifiable (and privacy-leaking) proof from it.
                if let dleq = sig.dleq,
                   let bData = Data(hex: input.B_),
                   let eData = Data(hex: dleq.e),
                   let sData = Data(hex: dleq.s) {
                    if !verifyDLEQAlice(B_: bData, C_: Cdata, A: pkData, e: eData, s: sData) {
                        cocoLog("❌ DLEQ verification failed for amount \(sig.amount); rejecting mint signature")
                        continue
                    }
                }

                var rK = try ec_tweak_mul_pubkey(&K, r)
                var neg_rK = try ec_negate(&rK)
                var C_unblinded = try ec_combine(&C_blinded, &neg_rK)

                let C_bytes = try ec_serialize_pubkey(&C_unblinded)
                let C_hex = C_bytes.map { String(format: "%02x", $0) }.joined()

                // Trust OUR record of which keyset we blinded against over the
                // mint's echoed id — the derivation counter and restore scans are
                // scoped by keyset ID, so letting the mint rename it would detach
                // the proof from its NUT-13 derivation branch.
                results.append(Proof(
                    amount: sig.amount,
                    mint: mint,
                    secret: secret,
                    C: C_hex,
                    keysetId: input.id
                ))
            } catch {
                cocoLog("❌ Unblind math failed: \(error)")
            }
        }

        return results
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
    
    /// NUT-12 DLEQ verification (public entry point; also used by tests).
    /// Returns true only when the proof is present AND valid.
    public func verifyDLEQ(blindedMessage B_: String, blindSignature C_: String, mintPubKey A: String, e: String, s: String) async -> Bool {
        guard let bData = Data(hex: B_), let cData = Data(hex: C_),
              let aData = Data(hex: A), let eData = Data(hex: e), let sData = Data(hex: s) else {
            return false
        }
        return verifyDLEQAlice(B_: bData, C_: cData, A: aData, e: eData, s: sData)
    }

    /// NUT-12 alice-side DLEQ check. Proves the mint used its published key `A` to
    /// produce the blind signature `C_` over the blinded message `B_`:
    ///   R1 = s·G − e·A
    ///   R2 = s·B_ − e·C_
    ///   e  == hash(R1, R2, A, C_)
    /// where hash concatenates the UNCOMPRESSED hex encodings of the four points and
    /// takes SHA256 (must match the mint's `hash_e` byte-for-byte).
    private func verifyDLEQAlice(B_: Data, C_: Data, A: Data, e: Data, s: Data) -> Bool {
        do {
            // R1 = s·G − e·A
            var sG = try ec_pubkey_from_scalar(s)
            var A_pt = try ec_parse_pubkey(A)
            var eA = try ec_tweak_mul_pubkey(&A_pt, e)
            var neg_eA = try ec_negate(&eA)
            var R1 = try ec_combine(&sG, &neg_eA)

            // R2 = s·B_ − e·C_
            var B_pt = try ec_parse_pubkey(B_)
            var sB = try ec_tweak_mul_pubkey(&B_pt, s)
            var C_pt = try ec_parse_pubkey(C_)
            var eC = try ec_tweak_mul_pubkey(&C_pt, e)
            var neg_eC = try ec_negate(&eC)
            var R2 = try ec_combine(&sB, &neg_eC)

            // e' = SHA256( uncompressed_hex(R1) || uncompressed_hex(R2) || uncompressed_hex(A) || uncompressed_hex(C_) )
            var A_hashPt = try ec_parse_pubkey(A)
            var C_hashPt = try ec_parse_pubkey(C_)
            let concat = try ec_serialize_pubkey_uncompressed(&R1).hexString
                + ec_serialize_pubkey_uncompressed(&R2).hexString
                + ec_serialize_pubkey_uncompressed(&A_hashPt).hexString
                + ec_serialize_pubkey_uncompressed(&C_hashPt).hexString
            let eComputed = sha256(Data(concat.utf8))
            return eComputed == e
        } catch {
            return false
        }
    }
    
    /// NUT-00 hash-to-curve — delegates to the shared Core implementation
    /// (`cashu_hash_to_curve`), which the NUT-07 checkstate request also uses.
    func hash_to_curve(_ message: Data) throws -> secp256k1_pubkey {
        do {
            return try cashu_hash_to_curve(message)
        } catch {
            throw CashuError.cryptoError("Could not hash secret to curve")
        }
    }

}

// Helper for SHA256 data access
private extension SHA256.Digest {
    var data: Data { Data(self) }
}
