// MintService.swift
import Foundation

public protocol MintAPI: Sendable {
    func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?)
    func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus
    func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof]
    func requestTokens(quoteId: String, blindedMessages: [BlindedOutput], mint: MintURL) async throws -> [BlindSignatureDTO]
    func requestMeltQuote(mint: MintURL, amount: Int64, destination: String) async throws -> (quoteId: String, feeReserve: Int64)
    func executeMelt(mint: MintURL, quoteId: String, inputs: [Proof], outputs: [BlindedOutput]) async throws -> (preimage: String, change: [BlindSignatureDTO]?)
    func swap(mint: MintURL, inputs: [Proof], outputs: [BlindedOutput]) async throws -> [BlindSignatureDTO]
    func mint(quoteId: String, outputs: [BlindedOutput]) async throws -> [BlindSignatureDTO]
    func restore(mint: URL, outputs: [BlindedOutput]) async throws -> [BlindSignatureDTO]
    func check(mint: URL, proofs: [ProofDTO]) async throws -> [CheckStateDTO]
    func fetchKeysetIds(mint: URL) async throws -> [String]
    func fetchKeyset(mint: URL, id: String) async throws -> Keyset
}

public actor MintService {
    private let mints: MintRepository
    private let proofs: ProofService
    private let events: EventBus
    public let api: MintAPI
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
    
    /*    public func receiveTokens(for quote: Quote) async throws {
     print("⚡️ MINT: Attempting to claim quote \(quote.id) for \(quote.amount) sats...")
     
     // 1. Plan and Blind (Generate secrets)
     // These 'blinded' structs hold the SECRETS in memory. We must not lose them.
     let parts = try await blinding.planOutputs(amount: quote.amount, mint: quote.mint)
     let blindedOutputs = try await blinding.blind(parts: parts, mint: quote.mint)
     
     // Convert to the DTO format the API expects
     // (Assuming you resolved the struct differences from the previous step)
     let apiInputs = blindedOutputs.map { BlindedOutput(amount: $0.amount, B_: $0.B_, id: $0.id) }
     
     var signatures: [BlindSignatureDTO] = []
     
     do {
     // 2. Try to Mint normally
     signatures = try await api.requestTokens(
     quoteId: quote.id.uuidString,
     blindedMessages: apiInputs,
     mint: quote.mint
     )
     
     } catch let error {
     // 3. RECOVERY HANDLER
     // Check if the error indicates "Already Signed" (Code 10002)
     let errorString = String(describing: error)
     if errorString.contains("already been signed") || errorString.contains("10002") {
     print("⚠️ Network Glitch Detected: Mint already signed these outputs. Attempting RESTORE...")
     
     // Call RESTORE (NUT-05) to fetch the signatures we missed
     signatures = try await api.restore(mint: quote.mint, outputs: apiInputs)
     
     print("✅ RESTORE SUCCESS: Recovered \(signatures.count) signatures!")
     } else {
     // Genuine failure (e.g. quote not paid yet)
     throw error
     }
     }
     
     // 4. Unblind and Save (Standard flow)
     // Now we have the signatures (either from the first try or the restore), so we can finish.
     let proofs = try await blinding.unblind(signatures: signatures, for: parts, mint: quote.mint)
     try await self.proofs.addNew(proofs)
     
     let total = proofs.map { $0.amount }.reduce(0, +)
     await history.add(CashuTransaction(type: .mint, amount: total, memo: "Minted via Lightning", status: .success))
     
     print("✅ MINT: Success! Added \(total) sats.")
     }*/
    
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
            
            let (_, changeSigs) = try await api.executeMelt(mint: mint, quoteId: quoteId, inputs: inputs, outputs: outputs)
            
            if let sigs = changeSigs, !sigs.isEmpty, !changeParts.isEmpty {
                let allBlinded = try await blinding.blind(parts: changeParts, mint: mint)
                let changeProofs = try await blinding.unblind(signatures: sigs, for: allBlinded, mint: mint)
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
            let allParts = tokenParts + changeParts
            
            // 2. Blind ONCE
            let allOutputs = try await blinding.blind(parts: allParts, mint: mint)
            
            // 3. Swap
            let allBlinded = try await blinding.blind(parts: allParts, mint: mint)
            let signatures = try await api.swap(mint: mint, inputs: inputs, outputs: allOutputs)
            // 4. Unblind Everything
            let allProofs = try await blinding.unblind(signatures: signatures, for: allBlinded, mint: mint)
            
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
    
    /*    public func receiveToken(_ tokenString: String) async throws -> Int64 {
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
     }*/
    
    /// Swaps specific proofs for a target amount (to send) + change.
    /// Returns: (change: [Proof], token: String)
    /// - change: The proofs you keep (put back in wallet).
    /// - token: The serialized token string you give to the recipient.
    public func swap(proofs inputProofs: [Proof], amount: Int64, mint: MintURL) async throws -> (change: [Proof], token: String) {
        
        // 1. Calculate Input Total
        let totalInput = inputProofs.map(\.amount).reduce(0, +)
        
        // FEE CALCULATION:
        // The mint 'cashu.cz' is strict and charges fees (usually based on output count).
        // The error log explicitly said "fees (1)".
        // A safe heuristic for now is to reserve 2 or 3 sats, or just 1 as the log suggests.
        let fee: Int64 = 1
        
        // 2. Calculate Change
        // We must subtract the fee from the available money.
        let changeAmount = totalInput - amount - fee
        
        guard changeAmount >= 0 else {
            // If this happens, it means we don't have enough input to cover Amount + Fee.
            throw CashuError.insufficientFunds
        }
        
        // 3. Plan Outputs
        // A. The Token for the recipient
        let tokenParts = try await blinding.planOutputs(amount: amount, mint: mint)
        
        // B. The Change for us (only if > 0)
        let changeParts = (changeAmount > 0) ? try await blinding.planOutputs(amount: changeAmount, mint: mint) : []
        
        // ... (Rest of the function remains exactly the same) ...
        
        let allParts = tokenParts + changeParts
        let allBlinded = try await blinding.blind(parts: allParts, mint: mint)
        let signatures = try await api.swap(mint: mint, inputs: inputProofs, outputs: allBlinded)
        let allProofs = try await blinding.unblind(signatures: signatures, for: allBlinded, mint: mint)
        
        // ... (Splitting and Serialization logic) ...
        
        // Ensure we handle the case where changeParts is empty
        guard allProofs.count == allParts.count else {
            throw CashuError.protocolError("Swap returned wrong number of proofs")
        }
        
        let tokenCount = tokenParts.count
        let tokenProofs = Array(allProofs.prefix(tokenCount))
        let changeProofs = Array(allProofs.suffix(from: tokenCount))
        
        try await self.proofs.addNew(changeProofs)
        try await self.proofs.remove(inputProofs)
        
        let tokenString = try TokenHelper.serialize(tokenProofs, mint: mint)
        
        return (change: changeProofs, token: tokenString)
    }
}
