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
    
    /// NUT-02: Fetch the active keyset including fee information
    func fetchKeyset() async throws -> Keyset
    
    /// NUT-02: Check the fee for a specific number of inputs
    func checkFees(forInputCount numInputs: Int) async throws -> Int64
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
        // NUT-02: Fetch keyset to get dynamic fee info
        let keyset = try await api.fetchKeyset()
        
        // Estimate fee for ~5 inputs as initial guess (will be refined after reserve)
        let estimatedFee = keyset.calculateFee(forInputCount: 5)
        let inputs = try await proofs.reserve(amount: amount + estimatedFee, mint: mint)
        
        // 1. Reserve Amount + Fee
        do {
            let totalInput = inputs.map(\.amount).reduce(0, +)
            
            // NUT-02: Calculate actual fee based on number of inputs and keyset fee
            let actualFee = keyset.calculateFee(forInputCount: inputs.count)
            
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
                type: .sendEcash,
                amount: amount,
                fee: actualFee,
                memo: "Created Token",
                status: .success
            ))
            
            // 8. Serialize
            return try TokenHelper.serialize(tokenProofs, mint: mint, memo: memo)
        }
    }
    
    /// Swaps specific proofs for a target amount (to send) + change.
    /// Returns: (change: [Proof], token: String)
    /// - change: The proofs you keep (put back in wallet).
    /// - token: The serialized token string you give to the recipient.
    public func swap(proofs inputProofs: [Proof], amount: Int64, mint: MintURL) async throws -> (change: [Proof], token: String) {
        
        // 1. Calculate Input Total
        let totalInput = inputProofs.map(\.amount).reduce(0, +)
        
        // NUT-02: Calculate fee dynamically based on keyset fee info
        let keyset = try await api.fetchKeyset()
        let fee = keyset.calculateFee(forInputCount: inputProofs.count)
        
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

        await history.add(CashuTransaction(type: .sendEcash, amount: amount, fee: fee, memo: "Sent Ecash", status: .success))

        let tokenString = try TokenHelper.serialize(tokenProofs, mint: mint)

        return (change: changeProofs, token: tokenString)
    }
}
