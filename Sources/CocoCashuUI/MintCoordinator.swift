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
        do {
            let proofs: [Proof]
            
            // Try explicit token request via RealMintAPI if possible
            if let qid = quoteId, let real = api as? RealMintAPI {
                proofs = try await real.requestTokens(quoteId: qid, mint: mint)
                // Fallback to Invoice
            } else if let inv = invoice {
                proofs = try await api.requestTokens(mint: mint, for: inv)
            } else {
                throw CashuError.invalidQuote
            }
            try await saveProofs(proofs, mint: mint)
            return
        } catch {
            // Fallback to NUT-04 execution if simple redemption failed
            if let qid = quoteId, let amt = amount {
                print("MintCoordinator: falling back to NUT-04 execute for \(qid)")
                try await executePaidQuote(mint: mint, quoteId: qid, amount: amt)
                return
            }
            throw error
        }
    }
    
    // MARK: - Private Helpers
    private func executePaidQuote(mint: URL, quoteId: String, amount: Int64) async throws {
        // 1. Plan
        let parts = try await blinding.planOutputs(amount: amount, mint: mint)
        
        // 2. Blind
        let blinded = try await blinding.blind(parts: parts, mint: mint)
        
        // 3. Execute (Using the mint() method we added to the protocol earlier)
        let signatures = try await api.mint(quoteId: quoteId, outputs: blinded)
        
        // 4. Unblind
        let proofs = try await blinding.unblind(signatures: signatures, for: parts, mint: mint)
        
        // 5. Save
        try await saveProofs(proofs, mint: mint)
        
        await manager.history.add(CashuTransaction(
            type: .mint,
            amount: amount,
            memo: "Minted via Lightning (NUT-04)",
            status: .success
        ))
    }
    
    private func saveProofs(_ proofs: [Proof], mint: URL) async throws {
        try await manager.proofService.addNew(proofs)
        // Emit event so UI updates immediately
        manager.events.emit(.proofsUpdated(mint: mint))
    }
    
}
