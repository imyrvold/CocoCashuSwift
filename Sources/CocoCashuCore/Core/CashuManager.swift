// CashuManager.swift
import Foundation

// Sendable weak box to avoid capturing `self` in Sendable closures
private final class WeakManagerBox: @unchecked Sendable {
  weak var value: CashuManager?
  init(_ value: CashuManager?) { self.value = value }
}

public final class CashuManager: @unchecked Sendable {
  public let events: EventBus
  public let proofService: ProofService
  public let quoteService: QuoteService
  public let mintService: MintService
  public let blinding: BlindingEngine
  private var plugins: [CashuPlugin] = []
  public let history: HistoryService

  public init(
    proofRepo: ProofRepository,
    mintRepo: MintRepository,
    quoteRepo: QuoteRepository,
    counterRepo: CounterRepository,
    api: MintAPI,
    blinding: BlindingEngine
  ) {
    events = EventBus()
    history = HistoryService(events: events)
    self.blinding = blinding
    let ps = ProofService(proofs: proofRepo, events: events)
    proofService = ps
    quoteService = QuoteService(quotes: quoteRepo, events: events)
      mintService = MintService(mints: mintRepo, proofs: ps, events: events, api: api, blinding: blinding, history: history)
  }

  public func use(_ plugin: CashuPlugin) async {
    self.plugins.append(plugin)
    await plugin.onManagerReady(manager: self)

    let box = WeakManagerBox(self)
    events.subscribe { evt in
      Task {
        if let plugins = box.value?.plugins {
          for plugin in plugins {
            await plugin.onEvent(evt)
          }
        }
      }
    }
  }

  public func dispose() {
    self.plugins.removeAll()
    // nothing else to tear down for now
  }
    
    public func send(amount: Int64, mint: MintURL) async throws -> String {
        // 1. RESERVE: Lock the proofs locally so we don't double-spend them.
        // We ask ProofService to pick enough unspent tokens.
        let proofsToSpend = try await proofService.reserve(amount: amount, mint: mint)
        
        do {
            print("🚀 SEND: Swapping \(amount) sats at \(mint)...")
            
            // 2. NETWORK: Call the Mint to swap these proofs for new ones.
            // We request 'amount' for the recipient (sendable) + change for us.
            // Note: You need to implement 'swap' in MintService or use your existing network call.
            // The return type should be (newProofs: [Proof], token: String) or similar.
            
            // Assuming mintService.swap returns (keptProofs, sendableToken)
            let (newProofs, tokenString) = try await mintService.swap(
                proofs: proofsToSpend,
                amount: amount,
                mint: mint
            )
            
            // 3. SUCCESS: The network call worked!
            // Now we update the local database permanently.
            
            // A. Mark the old reserved proofs as SPENT.
            try await proofService.markSpent(proofsToSpend.map(\.id), mint: mint)
            
            // B. Add the new "Change" proofs to our wallet.
            try await proofService.addNew(newProofs)
            
            print("✅ SEND: Success! Token: \(tokenString.prefix(10))...")
            return tokenString
            
        } catch {
            // 4. ROLLBACK: The network call failed (e.g. 400 Bad Request, 404, Internet Down).
            // We MUST release the reserved tokens so they show up in the balance again.
            
            print("❌ SEND FAILED: \(error). Rolling back transaction...")
            try await proofService.unreserve(proofsToSpend.map(\.id), mint: mint)
            
            // Re-throw the error so the UI can show "Send Failed"
            throw error
        }
    }
}
