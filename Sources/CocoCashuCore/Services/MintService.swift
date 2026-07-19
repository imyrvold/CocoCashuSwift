// MintService.swift
import Foundation

public protocol MintAPI: Sendable {
    func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?)
    func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus
    func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof]
    func requestTokens(quoteId: String, blindedMessages: [BlindedOutput], mint: MintURL) async throws -> [BlindSignatureDTO]
    func requestMeltQuote(mint: MintURL, amount: Int64, destination: String) async throws -> (quoteId: String, feeReserve: Int64, quotedAmount: Int64?)
    func executeMelt(mint: MintURL, quoteId: String, inputs: [Proof], outputs: [BlindedOutput]) async throws -> (preimage: String, change: [BlindSignatureDTO]?)
    func checkMeltQuote(mint: MintURL, quoteId: String) async throws -> (state: MeltState, change: [BlindSignatureDTO]?)
    func swap(mint: MintURL, inputs: [Proof], outputs: [BlindedOutput]) async throws -> [BlindSignatureDTO]
    func mint(quoteId: String, outputs: [BlindedOutput]) async throws -> [BlindSignatureDTO]
    /// NUT-09 restore. Returns the mint's echoed `outputs` (the matched blinded
    /// messages, in response order) alongside the `promises` (blind signatures).
    /// `outputs[i].B_` identifies which submitted output `promises[i]` belongs to,
    /// so callers can pair each signature to the exact secret/r that produced it
    /// instead of guessing.
    func restore(mint: URL, outputs: [BlindedOutput]) async throws -> (outputs: [BlindedOutput], promises: [BlindSignatureDTO])
    func check(mint: URL, proofs: [ProofDTO]) async throws -> [CheckStateDTO]
    func fetchKeysetIds(mint: URL) async throws -> [String]
    func fetchKeyset(mint: URL, id: String) async throws -> Keyset

    /// NUT-02: Fetch the active keyset (incl. fee info) from a SPECIFIC mint.
    /// Cross-mint flows (receiving a foreign token) must use this, not the
    /// default-mint variant below.
    func fetchKeyset(mint: URL) async throws -> Keyset

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
    
    /// Ceiling on the melt fee reserve this wallet will sign inputs for without
    /// refusing: the larger of 10 sats or 2% of the amount (Lightning routing
    /// fees are typically ≤1%). The mint dictates `fee_reserve`, but accepting it
    /// unbounded let a malicious mint quote e.g. 50,000 sats of "fee" on a
    /// 100-sat invoice and silently keep the difference.
    public static func maxAcceptableFeeReserve(forAmount amount: Int64) -> Int64 {
        max(10, amount / 50)
    }

    /// Spend tokens (melt) with Change handling.
    /// Returns `.paid` when the Lightning payment settles, or `.pending` when the
    /// mint accepted the melt but the payment is still in flight after polling
    /// (inputs parked for later reconciliation — the caller should present this as
    /// "processing", not an error). Throws only on genuine failures: bad quote,
    /// excessive fee, insufficient funds, or a definitive `meltUnpaid`.
    @discardableResult
    public func spend(amount: Int64, from mint: MintURL, to destination: String) async throws -> MeltResult {
        guard amount > 0 else { throw CashuError.protocolError("Melt amount must be positive") }

        // 1. Get Quote & Fee Reserve
        let (quoteId, feeReserve, quotedAmount) = try await api.requestMeltQuote(mint: mint, amount: amount, destination: destination)

        // The mint decodes the invoice itself; if its quoted amount disagrees with
        // what the caller parsed client-side, one of the two is wrong (buggy local
        // parser, or a mint quoting more than the invoice asks). Refuse rather than
        // reserve/spend an amount the user never saw.
        if let quoted = quotedAmount, quoted != amount {
            throw CashuError.protocolError("Mint quoted \(quoted) sats for this invoice but the wallet expected \(amount) — aborting")
        }

        // Validate the mint-dictated fee before signing anything over: reject
        // negative values, values that would overflow the sum, and values above
        // the sanity ceiling.
        guard feeReserve >= 0 else {
            throw CashuError.protocolError("Mint quoted a negative fee reserve (\(feeReserve))")
        }
        let feeCap = Self.maxAcceptableFeeReserve(forAmount: amount)
        guard feeReserve <= feeCap else {
            throw CashuError.protocolError("Mint quoted an excessive fee reserve of \(feeReserve) sats for a \(amount) sat payment (max acceptable: \(feeCap)). Refusing to proceed.")
        }

        // FIX: Add a small safety buffer (e.g., 3 sats) to handle fee spikes
        let safetyBuffer: Int64 = 3
        let (estimatedNeeded, overflowed) = amount.addingReportingOverflow(feeReserve)
        guard !overflowed else {
            throw CashuError.protocolError("Melt amount + fee overflows")
        }
        
        // 2. Reserve inputs covering the Amount + Fee + Buffer
        // This ensures we satisfy the "Provided < Needed" check even if fees rise.
        let inputs = try await proofs.reserve(amount: estimatedNeeded + safetyBuffer, mint: mint)
        let totalInput = inputs.map(\.amount).reduce(0, +)

        // PHASE A — Prepare change outputs. Any failure here happens BEFORE the melt
        // is submitted, so the inputs are untouched at the mint and safe to release.
        let outputs: [BlindedOutput]
        var changeParts: [Int64] = []
        do {
            let changeAmt = totalInput - estimatedNeeded
            if changeAmt > 0 {
                changeParts = try await blinding.planOutputs(amount: changeAmt, mint: mint)
                outputs = try await blinding.blind(parts: changeParts, mint: mint)
            } else {
                outputs = []
            }
        } catch {
            try? await proofs.unreserve(inputs.map(\.id), mint: mint)
            throw error
        }

        // PHASE B — Submit the melt. Once this request leaves, the mint may consume
        // the inputs even if we never see a clean response. The ONLY case where we
        // return inputs to spendable is a definitive "unpaid"; a PENDING/ambiguous
        // outcome goes to polling (below), never silently spendable.
        var changeSigs: [BlindSignatureDTO]? = nil
        var settled = false
        do {
            (_, changeSigs) = try await api.executeMelt(mint: mint, quoteId: quoteId, inputs: inputs, outputs: outputs)
            settled = true   // mint returned PAID synchronously
        } catch CashuError.meltUnpaid {
            try? await proofs.unreserve(inputs.map(\.id), mint: mint)
            throw CashuError.meltUnpaid
        } catch {
            // PENDING, timeout, or decode failure — the payment may be in flight.
            // Fall through to polling the melt quote to resolve it in-session.
            cocoLog("melt not settled synchronously (\(error)); polling melt quote…")
        }

        // PHASE B2 — Poll the NUT-05 melt quote until it settles. A small Lightning
        // payment routinely reports PENDING on the first call, so we give it a
        // window rather than surfacing that as a failure.
        if !settled {
            let outcome = await pollMeltUntilSettled(mint: mint, quoteId: quoteId)
            switch outcome {
            case .paid(let polledChange):
                changeSigs = polledChange
                settled = true
            case .unpaid:
                // Mint now reports the payment did not happen → safe to release.
                try? await proofs.unreserve(inputs.map(\.id), mint: mint)
                throw CashuError.meltUnpaid
            case .stillPending:
                // Genuinely unresolved after the window. Park the inputs and let the
                // next launch's reconcilePending finish the job. This is NOT a
                // failure — the payment may still complete.
                try? await proofs.markPending(inputs.map(\.id), mint: mint)
                await history.add(CashuTransaction(type: .melt, amount: amount, fee: 0, memo: "Payment processing", status: .pending))
                return .pending
            }
        }

        // PHASE C — Payment settled PAID, so the inputs ARE spent. Finalize that
        // first; only then attempt change recovery. A change-processing failure must
        // never resurrect the spent inputs, so it is caught and logged, not thrown.
        try await proofs.markSpent(inputs.map(\.id), mint: mint)

        if let sigs = changeSigs, !sigs.isEmpty, !changeParts.isEmpty {
            do {
                // Unblind against the SAME outputs we sent to the mint — re-blinding
                // here would derive different secrets and corrupt the change proofs.
                let changeProofs = try await blinding.unblind(signatures: sigs, for: outputs, mint: mint)
                try await proofs.addNew(changeProofs)
            } catch {
                cocoLog("⚠️ Melt paid but change recovery failed (change lost): \(error)")
            }
        }

        // RECORD HISTORY — Fee is roughly (Inputs - Change - Sent Amount)
        let totalChange = (changeSigs?.map(\.amount).reduce(0, +) ?? 0)
        let actualFee = totalInput - totalChange - amount
        await history.add(CashuTransaction(type: .melt, amount: amount, fee: actualFee, memo: "Paid Lightning Invoice", status: .success))
        return .paid(feePaid: max(0, actualFee))
    }

    private enum MeltPollOutcome { case paid([BlindSignatureDTO]?); case unpaid; case stillPending }

    /// Poll the melt quote state until it resolves to PAID/UNPAID or the window
    /// elapses. Transient poll errors (network blips) are ignored and retried —
    /// only a definitive PAID/UNPAID ends the loop early. Runs on the actor, so a
    /// concurrent operation still can't touch the reserved inputs meanwhile.
    private func pollMeltUntilSettled(mint: MintURL, quoteId: String, timeout: TimeInterval = 90, interval: UInt64 = 2_000_000_000) async -> MeltPollOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: interval)
            do {
                let (state, change) = try await api.checkMeltQuote(mint: mint, quoteId: quoteId)
                switch state {
                case .paid: return .paid(change)
                case .unpaid: return .unpaid
                case .pending, .unknown: continue
                }
            } catch {
                cocoLog("melt-quote poll error (will retry): \(error)")
                continue
            }
        }
        return .stillPending
    }

    /// Reconcile proofs parked as `.pending` by an ambiguous melt (NUT-07). For each,
    /// ask the mint its state: SPENT → the payment went through, finalize as spent;
    /// UNSPENT → the payment failed, return to spendable; PENDING → still in flight,
    /// leave for a later pass. Safe to call on launch and after network recovery.
    public func reconcilePending(mint: MintURL) async throws {
        let pending = try await proofs.pendingProofs(mint: mint)
        guard !pending.isEmpty else { return }

        let dtos: [ProofDTO] = pending.compactMap { p in
            guard let secretStr = String(data: p.secret, encoding: .utf8) else { return nil }
            return ProofDTO(amount: p.amount, secret: secretStr, C: p.C, id: p.keysetId)
        }
        guard dtos.count == pending.count else { return }

        // NUT-07 checkstate identifies proofs by Y = hash_to_curve(secret) —
        // match the response BY Y, never positionally (a reordering mint must
        // not finalize the wrong proof).
        let states = try await api.check(mint: mint, proofs: dtos)
        let stateByY = Dictionary(states.map { ($0.Y.lowercased(), $0.state) },
                                  uniquingKeysWith: { first, _ in first })

        var spentIds: [ProofId] = []
        var releaseIds: [ProofId] = []
        for proof in pending {
            guard let y = try? cashu_Y_hex(secret: proof.secret),
                  let state = stateByY[y] else { continue }
            switch state {
            case .spent:   spentIds.append(proof.id)
            case .unspent: releaseIds.append(proof.id)
            case .pending: break
            }
        }
        if !spentIds.isEmpty { try await proofs.markSpent(spentIds, mint: mint) }
        if !releaseIds.isEmpty { try await proofs.unreserve(releaseIds, mint: mint) }
    }
    
    // MARK: - Ecash Operations
    
    /// Create a token string for a specific amount.
    /// This effectively "spends" the funds from your wallet and returns them as a token string.
    public func createToken(amount: Int64, from mint: MintURL, memo: String? = nil, tokenVersion: TokenVersion = .v3) async throws -> String {
        // NUT-02: Fetch keyset to get dynamic fee info — from the mint we are
        // actually spending at, not the default mint (their fees can differ).
        let keyset = try await api.fetchKeyset(mint: mint)
        
        // Estimate fee for ~5 inputs as initial guess (will be refined after reserve)
        let estimatedFee = keyset.calculateFee(forInputCount: 5)
        let inputs = try await proofs.reserve(amount: amount + estimatedFee, mint: mint)

        // PHASE A — Everything before the swap request leaves the device. A failure
        // here means the mint never saw the inputs, so releasing them is safe.
        let tokenParts: [Int64]
        let allParts: [Int64]
        let allOutputs: [BlindedOutput]
        let actualFee: Int64
        do {
            let totalInput = inputs.map(\.amount).reduce(0, +)

            // NUT-02: Calculate actual fee based on number of inputs and keyset fee
            actualFee = keyset.calculateFee(forInputCount: inputs.count)

            // Calculate change so everything balances EXACTLY
            // Available = Input - Fee. Token = amount. Change = Remainder.
            let changeAmt = totalInput - actualFee - amount

            guard changeAmt >= 0 else {
                // If our initial estimate was too low and we picked too many small
                // inputs, we might be short. Fail and let the user retry.
                throw CashuError.insufficientFunds
            }

            tokenParts = try await blinding.planOutputs(amount: amount, mint: mint)
            let changeParts = (changeAmt > 0) ? try await blinding.planOutputs(amount: changeAmt, mint: mint) : []
            allParts = tokenParts + changeParts

            // Blind ONCE (blinding twice would derive a second, different set of
            // secrets and unblind against the wrong factors, producing invalid proofs).
            allOutputs = try await blinding.blind(parts: allParts, mint: mint)
        } catch {
            try? await proofs.unreserve(inputs.map(\.id), mint: mint)
            throw error
        }

        // PHASE B — Submit the swap. Once the request is out, the mint may have
        // consumed the inputs even without a clean response, so an error here parks
        // them `.pending` for NUT-07 reconciliation — NOT back to spendable (risking
        // double-spend) and NOT stranded `.reserved` forever (the old bug: this
        // block had no catch at all).
        let signatures: [BlindSignatureDTO]
        do {
            signatures = try await api.swap(mint: mint, inputs: inputs, outputs: allOutputs)
        } catch {
            try? await proofs.markPending(inputs.map(\.id), mint: mint)
            throw error
        }

        // PHASE C — The mint answered: the swap happened and the inputs are spent.
        // Failures past this point must not resurrect them.
        let allProofs: [Proof]
        do {
            allProofs = try await blinding.unblind(signatures: signatures, for: allOutputs, mint: mint)
            guard allProofs.count == allParts.count else {
                throw CashuError.protocolError("Mismatch in returned proofs count")
            }
        } catch {
            // Inputs are spent at the mint; the swapped-for proofs are recoverable
            // via a seed restore scan. Marking spent keeps local state truthful.
            try? await proofs.markSpent(inputs.map(\.id), mint: mint)
            throw error
        }

        let tokenCount = tokenParts.count
        let tokenProofs = Array(allProofs.prefix(tokenCount))
        let changeProofs = Array(allProofs.suffix(from: tokenCount))

        // Store Change, Mark Inputs Spent
        if !changeProofs.isEmpty { try await proofs.addNew(changeProofs) }
        try await proofs.markSpent(inputs.map(\.id), mint: mint)

        await history.add(CashuTransaction(
            type: .sendEcash,
            amount: amount,
            fee: actualFee,
            memo: "Created Token",
            status: .success
        ))

        return try TokenHelper.serialize(tokenProofs, mint: mint, memo: memo, version: tokenVersion)
    }

    /// Swaps specific proofs for a target amount (to send) + change.
    /// Returns: (change: [Proof], token: String)
    /// - change: The proofs you keep (put back in wallet).
    /// - token: The serialized token string you give to the recipient.
    public func swap(proofs inputProofs: [Proof], amount: Int64, mint: MintURL, tokenVersion: TokenVersion = .v3) async throws -> (change: [Proof], token: String) {
        
        // 1. Calculate Input Total
        let totalInput = inputProofs.map(\.amount).reduce(0, +)

        // NUT-02: Calculate fee dynamically based on keyset fee info — from the
        // mint whose proofs we are swapping, not the default mint.
        let keyset = try await api.fetchKeyset(mint: mint)
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

        let tokenString = try TokenHelper.serialize(tokenProofs, mint: mint, version: tokenVersion)

        return (change: changeProofs, token: tokenString)
    }
}
