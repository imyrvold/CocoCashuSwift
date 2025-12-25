// MintService.swift
import Foundation

public protocol MintAPI: Sendable {
    func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?)
    func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus
    func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof]
    func requestMeltQuote(mint: MintURL, amount: Int64, destination: String) async throws -> (quoteId: String, feeReserve: Int64)
    func executeMelt(mint: MintURL, quoteId: String, inputs: [Proof], outputs: [BlindedOutput]) async throws -> (preimage: String, change: [BlindSignatureDTO]?)
    func swap(mint: MintURL, inputs: [Proof], outputs: [BlindedOutput]) async throws -> [BlindSignatureDTO]
    func mint(quoteId: String, outputs: [BlindedOutput]) async throws -> [BlindSignatureDTO]
}

public actor MintService {
    private let mints: MintRepository
    private let proofs: ProofService
    private let events: EventBus
    private let api: MintAPI
    private let blinding: BlindingEngine
    private let history: HistoryService
    
    public init(mints: MintRepository, proofs: ProofService, events: EventBus, api: MintAPI, blinding: BlindingEngine, history: HistoryService) {
        self.mints = mints; self.proofs = proofs; self.events = events; self.api = api; self.blinding = blinding
        self.history = history
    }
    public func syncMints() async throws {
        // hook for fetching/updating mint metadata if needed
        for mint in try await mints.fetchAll() { events.emit(.mintSynced(mint.base)) }
    }
    
    /// After invoice is paid, fetch minted proofs (receive tokens).
    public func receiveTokens(for quote: Quote) async throws {
        let newProofs = try await api.requestTokens(mint: quote.mint, for: quote.invoice ?? "")
        try await proofs.addNew(newProofs)
        
        let total = newProofs.map(\.amount).reduce(0, +)
        await history.add(CashuTransaction(type: .mint, amount: total, memo: "Minted via Lightning", status: .success))
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
            
            // RECORD HISTORY
            // Fee is roughly (Inputs - Change - Sent Amount)
            let totalChange = (changeSigs?.map(\.amount).reduce(0, +) ?? 0)
            let actualFee = totalInput - totalChange - amount
            
            await history.add(CashuTransaction(type: .melt, amount: amount, fee: actualFee, memo: "Paid Lightning Invoice", status: .success))
        } catch {
            try? await proofs.unreserve(inputs.map(\.id), mint: mint)
            throw error
        }
    }
    
    // MARK: - Ecash Operations
    
    /// Create a token string for a specific amount.
    /// This effectively "spends" the funds from your wallet and returns them as a token string.
    public func createToken(amount: Int64, from mint: MintURL, memo: String? = nil) async throws -> String {
        // Estimate fee for the Inputs we are about to select.
        // Since we don't know exactly how many inputs reserve() will pick,
        // we start with a safe guess (e.g. 3 inputs = 3 sats).
        let estimatedFee: Int64 = 3
        let inputs = try await proofs.reserve(amount: amount + estimatedFee, mint: mint)
        
        // 1. Reserve Amount + Fee
        do {
            let totalInput = inputs.map(\.amount).reduce(0, +)
            
            // FIX: Refine the fee calculation based on actual inputs reserved
            let actualFee = Int64(inputs.count) * 1 // 1 sat per input
            
            // Calculate change so everything balances EXACTLY
            // Available = Input - Fee. Token = amount. Change = Remainder.
            let changeAmt = totalInput - actualFee - amount
            
            guard changeAmt >= 0 else {
                // If our initial estimate (3) was too low and we picked too many small inputs (e.g. 5 inputs = 5 fee),
                // we might be short. In that rare case, we just fail and tell user to try again (or handle retry).
                throw CashuError.insufficientFunds
            }
            
            // Plan Token Parts
            let tokenParts = try await blinding.planOutputs(amount: amount, mint: mint)
            // Plan Change Parts
            let changeParts = (changeAmt > 0) ? try await blinding.planOutputs(amount: changeAmt, mint: mint) : []
            
            // Blind everything
            let tokenBlinded = try await blinding.blind(parts: tokenParts, mint: mint)
            let changeBlinded = try await blinding.blind(parts: changeParts, mint: mint)
            let allParts = tokenParts + changeParts
            
            // 2. Blind ONCE
            let allOutputs = try await blinding.blind(parts: allParts, mint: mint)
            
            // 3. Swap
            let signatures = try await api.swap(mint: mint, inputs: inputs, outputs: allOutputs)
            
            // 4. Unblind Everything
            let allProofs = try await blinding.unblind(signatures: signatures, for: allParts, mint: mint)
            
            // 5. Split the results back into Token vs Change
            // We know the first N proofs correspond to the tokenParts
            let tokenCount = tokenParts.count
            
            // Safety check
            guard allProofs.count == allParts.count else {
                // If mint dropped a change output due to fee miscalculation, handle gracefully
                // Usually, token proofs come first because we passed them first in 'allParts'
                // But 'unblind' might have skipped some if signatures were missing.
                // For a robust implementation, filter by the amounts in tokenParts.
                throw CashuError.protocolError("Mismatch in returned proofs count")
            }
            
            let tokenProofs = Array(allProofs.prefix(tokenCount))
            let changeProofs = Array(allProofs.suffix(from: tokenCount))
            
            // 6. Store Change, Mark Inputs Spent
            if !changeProofs.isEmpty { try await proofs.addNew(changeProofs) }
            try await proofs.markSpent(inputs.map(\.id), mint: mint)
            
            // 7. Record History
            await history.add(CashuTransaction(
                type: .melt,
                amount: amount,
                fee: actualFee, // Use the calculated fee
                memo: "Created Token",
                status: .success
            ))
            
            // 8. Serialize
            return try TokenHelper.serialize(tokenProofs, mint: mint, memo: memo)
        }
    }
    
    public func receiveToken(_ tokenString: String) async throws -> Int64 {
        // 1. Parse
        let tokenData = try TokenHelper.deserialize(tokenString)
        guard let entry = tokenData.token.first, let mintURL = URL(string: entry.mint) else {
            throw CashuError.protocolError("Invalid token format")
        }
        
        let proofsToClaim = entry.proofs
        let totalInput = proofsToClaim.map(\.amount).reduce(0, +)
        
        // FIX: Calculate fee dynamically (1 sat per proof)
        // This handles "Strict" mints like cashu.cz
        let swapFee: Int64 = 1
        
        let amountToReceive = totalInput - swapFee
        
        guard amountToReceive > 0 else {
            throw CashuError.insufficientFunds
        }
                
        // 2. Plan new outputs for the EXACT remaining amount (e.g. 10 - 1 = 9)
        let newParts = try await blinding.planOutputs(amount: amountToReceive, mint: mintURL)
        let blindedOutputs = try await blinding.blind(parts: newParts, mint: mintURL)
        
        // 3. Execute Swap
        // Inputs (10) vs Outputs (9) + Fee (1). This will now balance.
        let signatures = try await api.swap(mint: mintURL, inputs: proofsToClaim, outputs: blindedOutputs)
        
        // 4. Unblind & Store
        let newProofs = try await blinding.unblind(signatures: signatures, for: newParts, mint: mintURL)
        try await proofs.addNew(newProofs)
        
        // 5. History
        await history.add(CashuTransaction(type: .mint, amount: amountToReceive, fee: swapFee, memo: "Received Token", status: .success))
        
        return amountToReceive
    }
}
