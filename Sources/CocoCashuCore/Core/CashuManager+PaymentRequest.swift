import Foundation

public extension CashuManager {
    /// Fulfil a NUT-18 payment request (the tap-to-pay PAYER side): produce a
    /// token that satisfies the request, to hand back to the receiver in-band
    /// (over the same NFC tap, or a scanned/returned QR).
    ///
    /// Requires an amount and the sat unit. If the request names mints, the
    /// token is created at one of THOSE we hold enough balance at (a request can
    /// insist on its own mint); otherwise at our best-covering mint. Transports
    /// (nostr/post) are intentionally ignored here — the caller's tap/scan IS the
    /// transport, and the response is the returned token string.
    func fulfillPaymentRequest(_ request: PaymentRequest, tokenVersion: TokenVersion = .v3) async throws -> String {
        guard let amount = request.amount, amount > 0 else {
            throw CashuError.protocolError("Payment request does not specify an amount")
        }
        if let unit = request.unit, unit.lowercased() != "sat" {
            throw CashuError.protocolError("Unsupported payment request unit '\(unit)' — only sat is supported")
        }

        let current = await balances()
        let candidates: [(mint: URL, balance: Int64)]
        if request.mints.isEmpty {
            candidates = current
        } else {
            let allowed = Set(request.mints.compactMap { URL(string: $0) }.map { MintSelection.key($0) })
            candidates = current.filter { allowed.contains(MintSelection.key($0.mint)) }
            guard !candidates.isEmpty else {
                throw CashuError.protocolError("This request needs funds at a mint you don't hold balance with: \(request.mints.joined(separator: ", "))")
            }
        }

        guard let mint = MintSelection.pick(covering: amount, from: candidates) else {
            throw CashuError.insufficientFunds
        }
        return try await mintService.createToken(amount: amount, from: mint,
                                                  memo: request.description, tokenVersion: tokenVersion)
    }
}
