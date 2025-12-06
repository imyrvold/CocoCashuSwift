// MintService.swift
import Foundation

public protocol MintAPI: Sendable {
    func requestMintQuote(mint: MintURL, amount: Int64) async throws -> (invoice: String, expiresAt: Date?, quoteId: String?)
  func checkQuoteStatus(mint: MintURL, invoice: String) async throws -> QuoteStatus
  func requestTokens(mint: MintURL, for invoice: String) async throws -> [Proof]
  func melt(mint: MintURL, proofs: [Proof], amount: Int64, destination: String) async throws -> (preimage: String, change: [Proof]?)
}

public actor MintService {
  private let mints: MintRepository
  private let proofs: ProofService
  private let events: EventBus
  private let api: MintAPI

  public init(mints: MintRepository, proofs: ProofService, events: EventBus, api: MintAPI) {
    self.mints = mints; self.proofs = proofs; self.events = events; self.api = api
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

  /// Spend tokens (melt) to a destination (e.g., bolt11 invoice)
  public func spend(amount: Int64, from mint: MintURL, to destination: String) async throws {
      let feeBuffer = max(2, Int64(Double(amount) * 0.02))
        let totalNeeded = amount + feeBuffer
        
        // Reserve the total amount (invoice + buffer)
        let reserved = try await proofs.reserve(amount: totalNeeded, mint: mint)
        
        do {
          // Send all reserved proofs. The mint will melt 'amount' and return the rest as new tokens (change).
          let res = try await api.melt(mint: mint, proofs: reserved, amount: amount, destination: destination)
          
          // Mark the input proofs as spent
          try await proofs.markSpent(reserved.map(\.id), mint: mint)
          
          // Add the change proofs back to the wallet
          if let change = res.change, !change.isEmpty {
            try await proofs.addNew(change)
          }
        } catch {
          // If it fails, unreserve the proofs so they don't get stuck
          try? await proofs.unreserve(reserved.map(\.id), mint: mint)
          throw error
        }
  }
}
