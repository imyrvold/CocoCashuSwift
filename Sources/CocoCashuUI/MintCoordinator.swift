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
            cocoLog("MintCoordinator: executing mint for quote \(qid)")
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
        cocoLog("⚡️ MINT: Starting mint flow for \(amount) sats (Quote: \(quoteId))")
        
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
                cocoLog("⚠️ Network Glitch Detected: Mint already signed these outputs. Attempting RESTORE...")
                
                // Try to cast to RealMintAPI to access the specific 'restore' endpoint
                if let realApi = api as? RealMintAPI {
                    // Recovery path: we submitted exactly these outputs, so the promises
                    // map back to them by amount in unblind(); we only need the promises.
                    signatures = try await realApi.restore(mint: mint, outputs: blindedOutputs).promises
                    cocoLog("✅ RESTORE SUCCESS: Recovered \(signatures.count) signatures!")
                } else {
                    cocoLog("❌ Restore failed: API is not RealMintAPI")
                    throw error
                }
            } else {
                // Genuine failure (e.g. Quote not paid yet)
                cocoLog("❌ MINT FAILED: \(error)")
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

        cocoLog("✅ MINT COMPLETE: Added \(total) sats to wallet.")
    }
    
    private func saveProofs(_ proofs: [Proof], mint: URL) async throws {
        try await manager.proofService.addNew(proofs)
        let total = proofs.map { $0.amount }.reduce(0, +)
        await manager.history.add(CashuTransaction(type: .mint, amount: total, fee: 0, memo: "Minted via Lightning", status: .success))
        manager.events.emit(.proofsUpdated(mint: mint))
    }
    
    // MARK: - Receive (Swap) Logic

    public func receive(token: String) async throws {
        cocoLog("📥 RECEIVE: Processing token...")
        
        // 1. Parse the Token
        // We decode the string to get the proofs and the Mint URL.
        let (proofs, mintUrl) = try parseToken(token)

        // Every proof amount must be positive, and the total must not overflow —
        // a crafted token with a negative or Int64.max amount would otherwise
        // corrupt fee math or trap the app.
        var totalAmount: Int64 = 0
        for p in proofs {
            guard p.amount > 0 else { throw CashuError.invalidToken }
            let (sum, overflow) = totalAmount.addingReportingOverflow(p.amount)
            guard !overflow else { throw CashuError.invalidToken }
            totalAmount = sum
        }

        // NUT-02: the swap fee is dictated by the keyset's input_fee_ppk, not a fixed
        // guess. Hardcoding 1 made outputs short by 1 on zero-fee mints (e.g. cashu.cz),
        // so the mint rejected the swap as "not balanced" (code 11000).
        // Fetch it from the TOKEN's mint — the fee keyset, blinding keyset, and swap
        // endpoint must all be the same mint or a foreign token's receive derives
        // outputs against one server and submits proofs to another.
        let keyset = try await api.fetchKeyset(mint: mintUrl)
        let estimatedFee = keyset.calculateFee(forInputCount: proofs.count)
        let amountToReceive = totalAmount - estimatedFee

        guard amountToReceive > 0 else {
            throw CashuError.cryptoError("Fee (\(estimatedFee)) exceeds token value (\(totalAmount))")
        }

        cocoLog("📥 RECEIVE: Input \(totalAmount) - Fee \(estimatedFee) = \(amountToReceive) sats")
        
        // 4. Split into powers of 2 (Standard Cashu Logic)
        // e.g. If amountToReceive is 3, this returns [1, 2]
        let outputAmounts = splitIntoPowersOf2(amountToReceive)

        // 5-7. Blind → Swap → Unblind, with self-healing on output collisions.
        // If the mint reports our blinded outputs as already-signed/pending (NUT-13
        // index reuse, e.g. after a counter reset), re-derive with fresh indices and
        // retry — each blind() reserves a new counter range, so the outputs differ.
        let maxAttempts = 8
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                let blindedOutputs = try await blinding.blind(parts: outputAmounts, mint: mintUrl)
                let signatures = try await api.swap(mint: mintUrl, inputs: proofs, outputs: blindedOutputs)
                let newProofs = try await blinding.unblind(signatures: signatures, for: blindedOutputs, mint: mintUrl)

                try await manager.proofService.addNew(newProofs)
                // Remember this mint: multi-mint operations (scan-all,
                // reconcile-all, balance breakdown) must find it later even if
                // these proofs get spent.
                await manager.registerMint(mintUrl)
                await manager.history.add(CashuTransaction(type: .receiveEcash, amount: amountToReceive, fee: estimatedFee, memo: "Received Ecash", status: .success))
                manager.events.emit(.proofsUpdated(mint: mintUrl))
                cocoLog("✅ CLAIM COMPLETE: Added \(amountToReceive) sats to wallet.")
                return
            } catch {
                lastError = error
                if Self.isOutputCollision(error), attempt < maxAttempts {
                    cocoLog("⚠️ RECEIVE: outputs collided (attempt \(attempt)/\(maxAttempts)) — retrying with fresh derivation indices…")
                    continue
                }
                throw error
            }
        }
        throw lastError ?? CashuError.network("Receive failed after \(maxAttempts) attempts")
    }

    /// True when the mint rejects our *outputs* as already-signed or pending
    /// (NUT-13 index reuse), which a fresh re-derivation can recover from.
    private static func isOutputCollision(_ error: Error) -> Bool {
        let s = String(describing: error).lowercased()
        return s.contains("11004")               // outputs are pending
            || s.contains("10002")               // blinded message already signed
            || s.contains("outputs are pending")
            || s.contains("already signed")
            || s.contains("already been signed")
    }
    
    // MARK: - Token Parsing Helper

    /// Bounds on untrusted pasted/scanned tokens: without them a crafted blob with
    /// millions of proofs is fully decoded and then drives a keyset-fetch/blind/swap
    /// loop — a memory-and-network DoS from one paste.
    private static let maxTokenLength = 100_000
    private static let maxProofCount = 512

    private func parseToken(_ token: String) throws -> ([Proof], URL) {
        // 1. Basic Validation
        guard token.count > 6, token.count <= Self.maxTokenLength else {
            throw CashuError.invalidToken
        }

        // 2. Dispatch by NUT-00 version: cashuA = V3 (base64 JSON),
        //    cashuB = V4 (base64 CBOR — what Minibits/cashu.me send by default).
        if token.hasPrefix("cashuB") {
            return try parseTokenV4(token)
        }
        guard token.lowercased().hasPrefix("cashu") else {
            throw CashuError.invalidToken
        }
        return try parseTokenV3(token)
    }

    private func parseTokenV4(_ token: String) throws -> ([Proof], URL) {
        let decoded = try TokenV4Helper.deserialize(token)
        guard decoded.proofs.count <= Self.maxProofCount,
              let url = URL(string: decoded.mint) else {
            throw CashuError.invalidToken
        }
        // V4 tokens carry a unit; this wallet only handles sats.
        if let unit = decoded.unit, unit.lowercased() != "sat" {
            throw CashuError.protocolError("Unsupported token unit '\(unit)' — only sat is supported")
        }
        try RealMintAPI.requireSecure(url)

        let proofs: [Proof] = decoded.proofs.compactMap { p in
            guard let secretData = p.secret.data(using: .utf8) else { return nil }
            return Proof(
                amount: p.amount,
                mint: url,
                secret: secretData,
                C: p.C,
                keysetId: p.keysetId
            )
        }
        guard !proofs.isEmpty else { throw CashuError.invalidToken }
        return (proofs, url)
    }

    private func parseTokenV3(_ token: String) throws -> ([Proof], URL) {
        // Remove Prefix & Base64 Decode
        let idx = token.index(token.startIndex, offsetBy: 6) // Skip "cashuA"
        let b64 = String(token[idx...])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let padded = b64.padding(toLength: ((b64.count + 3) / 4) * 4, withPad: "=", startingAt: 0)

        guard let data = Data(base64Encoded: padded) else {
            throw CashuError.invalidToken
        }

        // Decode JSON (NUT-00 standard)
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
        guard entry.proofs.count <= Self.maxProofCount else {
            throw CashuError.invalidToken
        }
        // A token naming an http:// mint is either broken or a downgrade attempt;
        // refuse it explicitly instead of failing later with an opaque error.
        try RealMintAPI.requireSecure(url)

        // Convert to your App's Proof Model. NUT-00 secrets are plain UTF-8
        // strings — do NOT try base64 first: a 64-char hex secret is coincidentally
        // valid base64 and would silently decode into garbage bytes, making the
        // proof unspendable at the mint.
        let proofs = entry.proofs.compactMap { p -> Proof? in
            guard let secretData = p.secret.data(using: .utf8) else { return nil }
            return Proof(
                amount: p.amount,
                mint: url,
                secret: secretData,
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
