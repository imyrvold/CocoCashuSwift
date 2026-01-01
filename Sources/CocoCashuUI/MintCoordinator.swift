import Foundation
import CocoCashuCore

enum MintExecError: Error { case requiresBlinding(String) }

public final class MintCoordinator {
    public let manager: CashuManager
    public let api: MintAPI
    public let blinding: BlindingEngine
    
    public init(manager: CashuManager, api: MintAPI, blinding: BlindingEngine) {
        self.manager = manager
        self.api = api
        self.blinding = blinding
    }
    
    public func topUp(mint: URL, amount: Int64) async throws -> (invoice: String, quoteId: String?) {
        let q = try await api.requestMintQuote(mint: mint, amount: amount)
        return (q.invoice, q.quoteId)
    }

    public func pollUntilPaid(mint: URL, invoice: String?, quoteId: String?, timeout: TimeInterval = 120) async throws {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            let status: QuoteStatus
            if let qid = quoteId, let real = api as? RealMintAPI {
                status = try await real.checkQuoteStatus(quoteId: qid)
            } else if let inv = invoice {
                status = try await api.checkQuoteStatus(mint: mint, invoice: inv)
            } else {
                throw CashuError.invalidQuote
            }
            if status == .paid { return }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw CashuError.network("Quote not paid in time")
    }
    
    public func receiveTokens(mint: URL, invoice: String?, quoteId: String?, amount: Int64?) async throws {
        // 1. Prefer the modern Quote flow (NUT-04)
        if let qid = quoteId, let amt = amount {
            print("MintCoordinator: executing mint for quote \(qid)")
            // This function (which you likely have defined elsewhere) handles the full blinding/unblinding cycle
            try await executePaidQuote(mint: mint, quoteId: qid, amount: amt)
            return
        }
        
        // 2. Legacy/Fallback for Invoice-only mints (NUT-03/old)
        else if let inv = invoice {
            // If 'api.requestTokens(mint:for:)' still returns [Proof], this is fine.
            // If that function was also updated to return signatures, this block needs similar refactoring.
            let proofs = try await api.requestTokens(mint: mint, for: inv)
            try await saveProofs(proofs, mint: mint)
            return
        }
        
        // 3. Error
        else {
            throw CashuError.invalidQuote
        }
    }
    
    // MARK: - Private Helpers
    // MARK: - Private Helpers
        
    private func executePaidQuote(mint: URL, quoteId: String, amount: Int64) async throws {
        print("⚡️ MINT: Starting mint flow for \(amount) sats (Quote: \(quoteId))")
        
        // 1. Plan and Blind
        // We generate the secrets here. We must keep 'blindedOutputs' in memory
        // to handle the "Restore" fallback if the network fails.
        let parts = try await blinding.planOutputs(amount: amount, mint: mint)
        let blindedOutputs = try await blinding.blind(parts: parts, mint: mint)
        
        var signatures: [BlindSignatureDTO] = []
        
        do {
            // 2. Attempt Request
            // We use the 'api' property your Coordinator already has.
            // Ensure RealMintAPI is updated to accept [BlindedOutput] as discussed.
            signatures = try await api.requestTokens(
                quoteId: quoteId,
                blindedMessages: blindedOutputs,
                mint: mint
            )
            
        } catch let error {
            // 3. RECOVERY LOGIC (The "Zombie Quote" Fix)
            let errorString = String(describing: error)
            
            // Check for "Already Signed" (Error 10002)
            if errorString.contains("already been signed") || errorString.contains("10002") {
                print("⚠️ Network Glitch Detected: Mint already signed these outputs. Attempting RESTORE...")
                
                // Try to cast to RealMintAPI to access the specific 'restore' endpoint
                if let realApi = api as? RealMintAPI {
                    signatures = try await realApi.restore(mint: mint, outputs: blindedOutputs)
                    print("✅ RESTORE SUCCESS: Recovered \(signatures.count) signatures!")
                } else {
                    print("❌ Restore failed: API is not RealMintAPI")
                    throw error
                }
            } else {
                // Genuine failure (e.g. Quote not paid yet)
                print("❌ MINT FAILED: \(error)")
                throw error
            }
        }
        
        // 4. Unblind & Save
        let proofs = try await blinding.unblind(signatures: signatures, for: blindedOutputs, mint: mint)
        
        // Use the 'manager' property to access proofService
        try await manager.proofService.addNew(proofs)
        
        // Update UI
        let total = proofs.map { $0.amount }.reduce(0, +)
        manager.events.emit(.proofsUpdated(mint: mint))
        
        print("✅ MINT COMPLETE: Added \(total) sats to wallet.")
    }
    
    private func saveProofs(_ proofs: [Proof], mint: URL) async throws {
        try await manager.proofService.addNew(proofs)
        // Emit event so UI updates immediately
        manager.events.emit(.proofsUpdated(mint: mint))
    }
    
}
