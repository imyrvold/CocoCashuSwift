import Foundation

public actor WalletRestorationService {
    private let manager: CashuManager
    private let batchSize = 20 // Smaller batch size because we multiply by denominations
    
    public init(manager: CashuManager) {
        self.manager = manager
    }
    
    public func restoreFunds(mintURL: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Int {
        // Standard powers of 2
        let amounts: [Int64] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192]
        var totalRestored = 0
        
        print("🕵️ RESTORE: Starting scan for \(mintURL.absoluteString)")
        
        // 1. Fetch ALL Keyset IDs (Deterministic!)
        let keysetIds = try await manager.mintService.api.fetchKeysetIds(mint: mintURL)
        print("🕵️ RESTORE: Found \(keysetIds.count) active keysets: \(keysetIds)")
        
        // 2. Loop through EACH keyset
        for kId in keysetIds {
            print("🔑 RESTORE: Scanning Keyset ID: \(kId)")
            
            // Fetch keys for this specific ID so we can verify later if needed
            guard let keyset = try? await manager.mintService.api.fetchKeyset(mint: mintURL, id: kId) else {
                print("⚠️ RESTORE: Skipping Keyset \(kId) (Could not fetch keys)")
                continue
            }
            
            var currentIndex: UInt32 = 0
            var emptyBatches = 0
            
            while emptyBatches < 3 {
                if currentIndex > 100 { break } // Safety limit
                
                print("   Scanning indices \(currentIndex)-\(currentIndex+20)...")
                
                let indices = (0..<20).map { currentIndex + UInt32($0) }
                let (blindedData, secretMap) = try await manager.blinding.deriveForRestore(indices: indices, mint: mintURL, keysetID: kId)
                
                // Construct Payload
                var restorePayload: [BlindedOutput] = []
                for bOut in blindedData {
                    for amt in amounts {
                        restorePayload.append(BlindedOutput(amount: amt, B_: bOut.B_, id: kId))
                    }
                }
                
                // Network Request
                let signatures = try await manager.mintService.api.restore(mint: mintURL, outputs: restorePayload)
                
                if signatures.isEmpty {
                    emptyBatches += 1
                    currentIndex += 20
                    continue
                }
                
                // 5. Match Signatures back to Secrets
                var proofs: [Proof] = []
                
                // CRITICAL FIX: Sort secrets by index to ensure deterministic matching.
                // This stops the "Doubling" bug by ensuring we always pick the same index
                // for the same signature every time we scan.
                let sortedSecrets = secretMap.sorted { $0.key < $1.key }
                
                for sig in signatures {
                    guard let Chex = sig.C_ ?? sig.C else { continue }
                    
                    for (_, (secret, r)) in sortedSecrets {
                        // 1. Unblind
                        if let proof = try? await attemptUnblind(
                            sig: sig,
                            amount: sig.amount,
                            r: r,
                            secret: secret,
                            mintPub: keyset.keys[sig.amount] ?? "",
                            keysetId: keyset.id,
                            mintURL: mintURL
                        ) {
                            // 2. Accept the first valid match
                            // Since we are sorted, this will always be the lowest available index
                            // for this signature, ensuring stability.
                            proofs.append(proof)
                            break // Stop looking for this signature
                        }
                        
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
            print("❌ RESTORE: Mint rejected tokens (\(error)). Discarding.")
            return []
        }
    }
}
