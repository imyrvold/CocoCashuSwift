import Foundation
import CocoCashuCore

enum MintExecError: Error { case requiresBlinding(String) }

final class MintCoordinator {
  let manager: CashuManager
  let api: MintAPI
    let blinding: BlindingEngine

    init(manager: CashuManager, api: MintAPI, blinding: BlindingEngine = NoopBlindingEngine()) {
      self.manager = manager
      self.api = api
      self.blinding = blinding
    }
    
  func topUp(mint: URL, amount: Int64) async throws -> (invoice: String, quoteId: String?) {
      print("MintCoordinator ggsd", #function)
    let q = try await api.requestMintQuote(mint: mint, amount: amount)
      print("MintCoordinator ggsd", #function, "q:", q)
    return (q.invoice, q.quoteId)
  }

    func pollUntilPaid(mint: URL, invoice: String?, quoteId: String?, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let status: QuoteStatus
        if let qid = quoteId, let real = api as? RealMintAPI {
          status = try await real.checkQuoteStatus(quoteId: qid)
        } else if let inv = invoice {
          status = try await api.checkQuoteStatus(mint: mint, invoice: inv)
        } else {
          throw CashuError.invalidQuote
        }
        print("pollUntilPaid status:", status)
        if status == .paid { return }
      try await Task.sleep(nanoseconds: 2_000_000_000)
    }
    throw CashuError.network("Quote not paid in time")
  }
    
    /// Execute a PAID quote via NUT-04: plan -> blind -> execute -> unblind -> store
    private func executePaidQuote(mint: URL, quoteId: String, amount: Int64) async throws {

      // 1) Choose denomination split for `amount` (e.g., 10 -> [8,2])
      let parts = try await blinding.planOutputs(amount: amount, mint: mint)

      // 2) Produce blinded outputs (B_) and keep blinding secrets internally
      let blinded = try await blinding.blind(parts: parts, mint: mint) // [BlindedOutput]

      // 3) Execute the mint: POST /v1/mint/bolt11 { quote, outputs }

      // 4) Unblind signatures into spendable Proofs
        let signatures = try await api.mint(quoteId: quoteId, outputs: blinded)
        let proofs = try await blinding.unblind(signatures: signatures, for: parts, mint: mint)
        // 5) Store proofs and notify listeners
        manager.events.emit(.proofsUpdated(mint: mint))
      try await manager.proofService.addNew(proofs)
      manager.events.emit(.proofsUpdated(mint: mint))
        await manager.history.add(CashuTransaction(
            type: .mint,
            amount: amount,
            memo: "Minted via Lightning (NUT-04)",
            status: .success
        ))
    }

    func receiveTokens(mint: URL, invoice: String?, quoteId: String?, amount: Int64?) async throws {
      // First, try the simpler paths many mints still support
      do {
        let proofs: [Proof]
        if let qid = quoteId, let real = api as? RealMintAPI {
          proofs = try await real.requestTokens(quoteId: qid, mint: mint)
        } else if let inv = invoice {
          proofs = try await api.requestTokens(mint: mint, for: inv)
        } else {
          throw CashuError.invalidQuote
        }
        try await manager.proofService.addNew(proofs)
        manager.events.emit(.proofsUpdated(mint: mint))
          
          let total = proofs.map(\.amount).reduce(0, +)
          await manager.history.add(CashuTransaction(
            type: .mint,
            amount: total,
            memo: "Minted via Lightning",
            status: .success
          ))
        return
      } catch {
          // If redemption by quote/invoice failed, fall back to proper NUT-04 execution
          if let qid = quoteId, let amt = amount {
              print("MintCoordinator: falling back to NUT-04 execute for \(qid)")
              try await executePaidQuote(mint: mint, quoteId: qid, amount: amt)
              return
          }
          throw error
      }
    }
}
