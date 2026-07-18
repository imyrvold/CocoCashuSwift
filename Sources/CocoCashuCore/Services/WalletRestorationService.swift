import Foundation

public actor WalletRestorationService {
    private let manager: CashuManager
    private let batchSize = 20 // Smaller batch size because we multiply by denominations
    
    public init(manager: CashuManager) {
        self.manager = manager
    }

    /// NUT-13 derivation is defined only for hex keyset IDs: version 00 (8-byte)
    /// and version 01 (33-byte). Mints still LIST legacy base64 keysets (e.g.
    /// 'ctv28hTYzQwr' on mint.minibits.cash) alongside current ones — this wallet
    /// can never have derived secrets under those, so the scan must SKIP them
    /// rather than fail the whole mint on the engine's (correct) refusal to derive.
    static func supportsNUT13Derivation(keysetId: String) -> Bool {
        guard let bytes = Data(hex: keysetId) else { return false }
        let lower = keysetId.lowercased()
        return (bytes.count == 8 && lower.hasPrefix("00"))
            || (bytes.count == 33 && lower.hasPrefix("01"))
    }

    public func restoreFunds(mintURL: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Int {
        var totalRestored = 0
        
        cocoLog("🕵️ RESTORE: Starting scan for \(mintURL.absoluteString)")
        
        // 1. Fetch ALL Keyset IDs (Deterministic!)
        let keysetIds = try await manager.mintService.api.fetchKeysetIds(mint: mintURL)
        cocoLog("🕵️ RESTORE: Found \(keysetIds.count) active keysets: \(keysetIds)")
        
        // 2. Loop through EACH keyset. Failures are isolated per keyset: one
        // unsupported or unreachable keyset must not abort the scan of the rest.
        for kId in keysetIds {
            cocoLog("🔑 RESTORE: Scanning Keyset ID: \(kId)")

            guard Self.supportsNUT13Derivation(keysetId: kId) else {
                cocoLog("⚠️ RESTORE: Skipping keyset \(kId) — legacy/unsupported ID format, no NUT-13 derivation exists for it")
                continue
            }

            // Fetch keys for this specific ID so we can verify later if needed
            guard let keyset = try? await manager.mintService.api.fetchKeyset(mint: mintURL, id: kId) else {
                cocoLog("⚠️ RESTORE: Skipping Keyset \(kId) (Could not fetch keys)")
                continue
            }

            var currentIndex: UInt32 = 0
            var emptyBatches = 0
            // Highest derivation index the mint returned a signature for, including
            // indices whose proofs are already SPENT — the counter must move past
            // all of them or the next blind() re-derives an already-signed secret.
            var maxSignedIndex: Int64 = -1

            do {
            while emptyBatches < 3 {
                if currentIndex > 100 { break } // Safety limit
                
                cocoLog("   Scanning indices \(currentIndex)-\(currentIndex+20)...")
                
                let indices = (0..<20).map { currentIndex + UInt32($0) }
                let (blindedData, secretMap) = try await manager.blinding.deriveForRestore(indices: indices, mint: mintURL, keysetID: kId)

                // Map each derived blinded message B_ back to its (secret, r). B_ is
                // amount-independent, so we send each B_ exactly once with a neutral
                // placeholder amount — the mint matches on B_ and echoes the real
                // signed amount in its promise. (The old code sent each B_ times every
                // denomination, which scrambled the correspondence.)
                var secretByB: [String: (secret: Data, r: Data)] = [:]
                var indexByB: [String: UInt32] = [:]
                for (offset, bOut) in blindedData.enumerated() where offset < indices.count {
                    if let sr = secretMap[indices[offset]] {
                        secretByB[bOut.B_] = sr
                        indexByB[bOut.B_] = indices[offset]
                    }
                }
                let restorePayload = blindedData.map { BlindedOutput(amount: 1, B_: $0.B_, id: kId) }

                // Network Request
                let (echoedOutputs, signatures) = try await manager.mintService.api.restore(mint: mintURL, outputs: restorePayload)

                if signatures.isEmpty {
                    emptyBatches += 1
                    currentIndex += 20
                    continue
                }

                if echoedOutputs.count != signatures.count {
                    cocoLog("⚠️ RESTORE: mint returned \(signatures.count) promises but \(echoedOutputs.count) echoed outputs; pairing the aligned prefix only.")
                }

                // 5. Pair each promise to the EXACT secret/r that produced its B_.
                // NUT-09 returns echoedOutputs[i] alongside signatures[i], so the B_ at
                // position i tells us which secret to unblind with. This replaces the old
                // "try every secret, accept the first that unblinds" loop, which always
                // matched secret index 0 (attemptUnblind succeeds for any well-formed
                // pair) and produced duplicate, unspendable proofs.
                var proofs: [Proof] = []
                for (i, sig) in signatures.enumerated() {
                    guard i < echoedOutputs.count else { break }
                    guard let (secret, r) = secretByB[echoedOutputs[i].B_] else { continue }
                    if let idx = indexByB[echoedOutputs[i].B_] {
                        maxSignedIndex = max(maxSignedIndex, Int64(idx))
                    }
                    guard let mintPub = keyset.keys[sig.amount] else { continue }
                    if let proof = try? await attemptUnblind(
                        sig: sig,
                        amount: sig.amount,
                        r: r,
                        secret: secret,
                        mintPub: mintPub,
                        keysetId: keyset.id,
                        mintURL: mintURL
                    ) {
                        proofs.append(proof)
                    }
                }
                
                if !proofs.isEmpty {
                    // Soft-fail verify (Keep existing logic)
                    let verified = try await verifyUnspent(proofs: proofs, mint: mintURL)
                    
                    if !verified.isEmpty {
                        try await manager.proofService.addNew(verified)
                        totalRestored += verified.count
                        emptyBatches = 0
                    } else {
                        emptyBatches += 1
                    }
                } else {
                    emptyBatches += 1
                }
                
                currentIndex += 20
            }
            } catch {
                // Per-keyset isolation: a network hiccup or protocol error on ONE
                // keyset must not abort the scan of the remaining keysets. The
                // counter fast-forward below still runs for whatever this keyset's
                // scan managed to see before failing.
                cocoLog("⚠️ RESTORE: keyset \(kId) scan aborted mid-way: \(error) — continuing with remaining keysets")
            }

            // CRITICAL: fast-forward the NUT-13 counter past every index the mint
            // signed. Without this, a wallet restored on a fresh device (counter 0)
            // re-derives already-signed secrets on its next mint/swap — the mint
            // rejects them (wallet bricked at this keyset) or re-issues a duplicate
            // proof that is only spendable once.
            if maxSignedIndex >= 0 {
                try await manager.counterRepo.advance(key: kId, to: maxSignedIndex + 1)
                cocoLog("⏩ RESTORE: advanced counter for keyset \(kId) to \(maxSignedIndex + 1)")
            }
        }

        return totalRestored
    }
    
    // Helper to try unblinding a specific pair
    private func attemptUnblind(sig: BlindSignatureDTO, amount: Int64, r: Data, secret: Data, mintPub: String, keysetId: String, mintURL: URL) async throws -> Proof? {
        guard let pkData = Data(hex: mintPub) else { return nil }
        guard let Chex = sig.C_ ?? sig.C, let Cdata = Data(hex: Chex) else { return nil }
        
        // C_unblinded = C_blinded - rK
        var K = try ec_parse_pubkey(pkData)
        var C_blinded = try ec_parse_pubkey(Cdata)
        var rK = try ec_tweak_mul_pubkey(&K, r)
        var neg_rK = try ec_negate(&rK)
        var C_unblinded = try ec_combine(&C_blinded, &neg_rK)
        
        let C_bytes = try ec_serialize_pubkey(&C_unblinded)
        let C_final = C_bytes.map { String(format: "%02x", $0) }.joined()
        
        // If we succeeded in math, this is a candidate.
        // Real verification would check if Proof is valid, but since we trust the Mint's return,
        // if the math works, it's likely the right pair.
        
        return Proof(
            amount: amount,
            mint: mintURL,
            secret: secret,
            C: C_final,
            keysetId: keysetId
        )
    }
    
    private func verifyUnspent(proofs: [Proof], mint: MintURL) async throws -> [Proof] {
        let dtos = proofs.compactMap { p -> ProofDTO? in
            guard let secretStr = String(data: p.secret, encoding: .utf8) else { return nil }
            return ProofDTO(amount: p.amount, secret: secretStr, C: p.C, id: p.keysetId)
        }
        guard !dtos.isEmpty else { return [] }
        
        do {
            // Ask Mint: "Are these unspent?"
            let state = try await manager.mintService.api.check(mint: mint, proofs: dtos)
            guard state.count == dtos.count else { return [] }
            
            var valid: [Proof] = []
            for (index, item) in state.enumerated() {
                if item.state == .unspent {
                    valid.append(proofs[index])
                }
            }
            return valid
            
        } catch {
            // STRICT MODE:
            // If the Mint throws error (404/400), the tokens are INVALID.
            // Return empty list to discard them.
            cocoLog("❌ RESTORE: Mint rejected tokens (\(error)). Discarding.")
            return []
        }
    }
}
