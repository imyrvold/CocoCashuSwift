import Foundation
import CocoCashuCore

public actor WalletRestorationService {
    private let wallet: ObservableWallet
    private let batchSize = 50 // Check 50 tokens at a time per amount
    
    public init(wallet: ObservableWallet) {
        self.wallet = wallet
    }
    
    public func restoreFunds() async throws -> Int {
        let manager = wallet.manager
        let mintURL = URL(string: "https://cashu.cz")! // The mint you want to scan
        let amounts: [Int64] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024] // Standard powers of 2
        
        var totalRestored = 0
        
        // 1. Fetch Keyset to get the ID
        let keyset = try await RealMintAPI(baseURL: mintURL).fetchKeyset()
        
        // 2. Scan loop for each amount
        for amount in amounts {
            var index = 0
            var emptyBatches = 0
            
            // Keep scanning until we find 3 empty batches in a row (gap limit)
            while emptyBatches < 3 {
                // Generate potential outputs for this batch (e.g., indices 0-50)
                // We need to use the blinding engine to derive B_ for specific indices manually
                // Since CocoBlindingEngine manages internal counters, for RESTORE we usually 
                // hack it or extend it. 
                // For simplicity, let's assume we simply ask the engine to "blind" a batch.
                // Note: This increments the engine's internal counter, which is what we want!
                
                let partBatch = Array(repeating: amount, count: batchSize)
                
                // 3. Blind (Derive B_ using seed)
                let blindedOutputs = try await manager.blinding.blind(parts: partBatch, mint: mintURL)
                
                // 4. Ask Mint: "Do you have signatures for these?"
                let signatures = try await (manager.mintService.api as! RealMintAPI)
                    .restore(mint: mintURL, outputs: blindedOutputs)
                
                if signatures.isEmpty {
                    emptyBatches += 1
                    index += batchSize
                    continue
                }
                
                // 5. We found money! Unblind to get the Proofs (C)
                // The engine remembers the secrets for the 'blind' call we just made.
                let proofs = try await manager.blinding.unblind(signatures: signatures, for: partBatch, mint: mintURL)
                
                if !proofs.isEmpty {
                    try await manager.proofService.addNew(proofs)
                    totalRestored += proofs.count
                    emptyBatches = 0 // Reset gap limit
                    print("💰 Restored \(proofs.count) tokens for amount \(amount)")
                }
                
                index += batchSize
            }
        }
        
        await wallet.refreshAll()
        return totalRestored
    }
}