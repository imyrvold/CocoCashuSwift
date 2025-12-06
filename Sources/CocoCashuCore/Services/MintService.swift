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
        // 1. Get Quote & Fee Reserve from Mint
        let (quoteId, feeReserve) = try await api.requestMeltQuote(mint: mint, amount: amount, destination: destination)
        
        // 2. Select Inputs to cover Amount + Fee
        let totalNeeded = amount + feeReserve
        let inputs = try await proofs.reserve(amount: totalNeeded, mint: mint)
        
        do {
            // 3. Calculate Change (Input - Needed)
            let totalInput = inputs.map(\.amount).reduce(0, +)
            let changeAmt = totalInput - totalNeeded
            
            // 4. Blind the Change (if any)
            let outputs: [BlindedOutput]
            var changeParts: [Int64] = []
            if changeAmt > 0 {
                changeParts = try await blinding.planOutputs(amount: changeAmt, mint: mint)
                outputs = try await blinding.blind(parts: changeParts, mint: mint)
            } else {
                outputs = []
            }
            
            // 5. Execute Melt (Send Inputs + Blinded Change)
            let (preimage, changeSigs) = try await api.executeMelt(mint: mint, quoteId: quoteId, inputs: inputs, outputs: outputs)
            
            // 6. Unblind Change Signatures into Proofs
            if let sigs = changeSigs, !sigs.isEmpty, !changeParts.isEmpty {
                let changeProofs = try await blinding.unblind(signatures: sigs, for: changeParts, mint: mint)
                try await proofs.addNew(changeProofs)
            }
            
            // 7. Mark Inputs as Spent
            try await proofs.markSpent(inputs.map(\.id), mint: mint)
            
        } catch {
            // Unreserve if failed
            try? await proofs.unreserve(inputs.map(\.id), mint: mint)
            throw error
        }
    }
}
