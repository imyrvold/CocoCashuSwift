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
        
        // Record history & update UI
        let total = proofs.map { $0.amount }.reduce(0, +)
        await manager.history.add(CashuTransaction(type: .mint, amount: total, fee: 0, memo: "Minted via Lightning", status: .success))
        manager.events.emit(.proofsUpdated(mint: mint))

        print("✅ MINT COMPLETE: Added \(total) sats to wallet.")
    }
    
    private func saveProofs(_ proofs: [Proof], mint: URL) async throws {
        try await manager.proofService.addNew(proofs)
        let total = proofs.map { $0.amount }.reduce(0, +)
        await manager.history.add(CashuTransaction(type: .mint, amount: total, fee: 0, memo: "Minted via Lightning", status: .success))
        manager.events.emit(.proofsUpdated(mint: mint))
    }
    
    // MARK: - Receive (Swap) Logic

    public func receive(token: String) async throws {
        print("📥 RECEIVE: Processing token...")
        
        // 1. Parse the Token
        // We decode the string to get the proofs and the Mint URL.
        let (proofs, mintUrl) = try parseToken(token)
        
        let totalAmount = proofs.reduce(0) { $0 + $1.amount }
        let estimatedFee: Int64 = 1
        let amountToReceive = totalAmount - estimatedFee
        
        guard amountToReceive > 0 else {
            throw CashuError.cryptoError("Fee (\(estimatedFee)) exceeds token value (\(totalAmount))")
        }
        
        print("📥 RECEIVE: Input \(totalAmount) - Fee \(estimatedFee) = \(amountToReceive) sats")
        
        // 4. Split into powers of 2 (Standard Cashu Logic)
        // e.g. If amountToReceive is 3, this returns [1, 2]
        let outputAmounts = splitIntoPowersOf2(amountToReceive)
        
        // 5. Blind
        let blindedOutputs = try await blinding.blind(parts: outputAmounts, mint: mintUrl)
        
        // 6. Swap
        let signatures = try await api.swap(mint: mintUrl, inputs: proofs, outputs: blindedOutputs)
        
        // 7. Unblind
        let newProofs = try await blinding.unblind(signatures: signatures, for: blindedOutputs, mint: mintUrl)
        
        // 5. Save to Wallet
        try await manager.proofService.addNew(newProofs)

        // 6. Record history & update UI
        await manager.history.add(CashuTransaction(type: .receiveEcash, amount: amountToReceive, fee: estimatedFee, memo: "Received Ecash", status: .success))
        manager.events.emit(.proofsUpdated(mint: mintUrl))
        print("✅ CLAIM COMPLETE: Added \(amountToReceive) sats to wallet.")
    }
    
    // MARK: - Token Parsing Helper
    private func parseToken(_ token: String) throws -> ([Proof], URL) {
        // 1. Basic Validation
        guard token.lowercased().hasPrefix("cashu"), token.count > 6 else {
            throw CashuError.invalidToken
        }
        
        // 2. Remove Prefix & Base64 Decode
        let idx = token.index(token.startIndex, offsetBy: 6) // Skip "cashuA"
        let b64 = String(token[idx...])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let padded = b64.padding(toLength: ((b64.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        
        guard let data = Data(base64Encoded: padded) else {
            throw CashuError.invalidToken
        }
        
        // 3. Decode JSON (NUT-00 standard)
        struct TokenV3: Decodable {
            struct TokenEntry: Decodable {
                let mint: String?
                let proofs: [DecodeProof]
            }
            let token: [TokenEntry]
        }
        
        // Temporary struct to decode proofs safely
        struct DecodeProof: Decodable {
            let amount: Int64
            let secret: String // Secret comes as a string in JSON
            let C: String
            let id: String?
        }
        
        let root = try JSONDecoder().decode(TokenV3.self, from: data)
        guard let entry = root.token.first, let mintString = entry.mint, let url = URL(string: mintString) else {
            throw CashuError.invalidToken
        }

        // 4. Convert to your App's Proof Model
        let proofs = entry.proofs.compactMap { p -> Proof? in
            var secretData = Data(base64Encoded: p.secret)
            if secretData == nil {
                secretData = p.secret.data(using: .utf8)
            }
            
            guard let validSecret = secretData else { return nil }
            
            return Proof(
                amount: p.amount,
                mint: url,
                // CRITICAL: Convert the secret string to Data (UTF8)
                secret: validSecret,
                C: p.C,
                keysetId: p.id ?? ""
            )
        }

        return (proofs, url)
    }
    
    private func splitIntoPowersOf2(_ amount: Int64) -> [Int64] {
        var parts: [Int64] = []
        var v = amount
        var power: Int64 = 1
        while v > 0 {
            if (v & 1) == 1 { parts.append(power) }
            v >>= 1
            power <<= 1
        }
        return parts
    }
    
}
