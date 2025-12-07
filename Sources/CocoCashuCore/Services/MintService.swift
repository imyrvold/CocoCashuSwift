// MintService.swift
import Foundation

public protocol MintAPI: Sendable {
    func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?)
    func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus
    func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof]
    func requestMeltQuote(mint: MintURL, amount: Int64, destination: String) async throws -> (quoteId: String, feeReserve: Int64)
    func executeMelt(mint: MintURL, quoteId: String, inputs: [Proof], outputs: [BlindedOutput]) async throws -> (preimage: String, change: [BlindSignatureDTO]?)

}

public actor MintService {
    private let mints: MintRepository
    private let proofs: ProofService
    private let events: EventBus
    private let api: MintAPI
    private let blinding: BlindingEngine
    
    public init(mints: MintRepository, proofs: ProofService, events: EventBus, api: MintAPI, blinding: BlindingEngine) {
        self.mints = mints; self.proofs = proofs; self.events = events; self.api = api; self.blinding = blinding
    }
    public func syncMints() async throws {
        // hook for fetching/updating mint metadata if needed
        for mint in try await mints.fetchAll() { events.emit(.mintSynced(mint.base)) }
    }
    
    /// After invoice is paid, fetch minted proofs (receive tokens).
    public func receiveTokens(for quote: Quote) async throws {
        let newProofs = try await api.requestTokens(mint: quote.mint, for: quote.invoice ?? "")
        try await proofs.addNew(newProofs)
    }
    
    /// Spend tokens (melt) with Change handling
    public func spend(amount: Int64, from mint: MintURL, to destination: String) async throws {
        // 1. Get Quote & Fee Reserve
        let (quoteId, feeReserve) = try await api.requestMeltQuote(mint: mint, amount: amount, destination: destination)
        
        // FIX: Add a small safety buffer (e.g., 3 sats) to handle fee spikes
        let safetyBuffer: Int64 = 3
        let estimatedNeeded = amount + feeReserve
        
        // 2. Reserve inputs covering the Amount + Fee + Buffer
        // This ensures we satisfy the "Provided < Needed" check even if fees rise.
        let inputs = try await proofs.reserve(amount: estimatedNeeded + safetyBuffer, mint: mint)
        
        do {
            // 3. Calculate Change
            // We ask for everything back (Total Input - Estimated Cost).
            // If the fee spikes, the Mint will consume part of this change, and our
            // "missing signature" warning logic will handle the dropped change output gracefully.
            let totalInput = inputs.map(\.amount).reduce(0, +)
            let changeAmt = totalInput - estimatedNeeded
            
            // ... (The rest of the logic remains exactly the same) ...
            
            let outputs: [BlindedOutput]
            var changeParts: [Int64] = []
            if changeAmt > 0 {
                changeParts = try await blinding.planOutputs(amount: changeAmt, mint: mint)
                outputs = try await blinding.blind(parts: changeParts, mint: mint)
            } else {
                outputs = []
            }
            
            let (preimage, changeSigs) = try await api.executeMelt(mint: mint, quoteId: quoteId, inputs: inputs, outputs: outputs)
            
            if let sigs = changeSigs, !sigs.isEmpty, !changeParts.isEmpty {
                let changeProofs = try await blinding.unblind(signatures: sigs, for: changeParts, mint: mint)
                try await proofs.addNew(changeProofs)
            }
            
            try await proofs.markSpent(inputs.map(\.id), mint: mint)
            
        } catch {
            try? await proofs.unreserve(inputs.map(\.id), mint: mint)
            throw error
        }
    }
}
