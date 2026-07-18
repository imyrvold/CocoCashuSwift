// ObservableWallet.swift
import Foundation
import Observation
import CocoCashuCore

@MainActor
private final class WeakBox<T: AnyObject>: @unchecked Sendable { weak var value: T?; init(_ value: T?) { self.value = value } }

@MainActor
@Observable
public final class ObservableWallet {
  public private(set) var proofsByMint: [String: [Proof]] = [:]
  public private(set) var quotes: [Quote] = []
  public private(set) var transactions: [CashuTransaction] = []
  public let manager: CashuManager

  public init(manager: CashuManager) {
    self.manager = manager
      Task {
          self.transactions = await manager.history.fetchAll()
      }
    let box = WeakBox(self)
    manager.events.subscribe { event in
      Task { @MainActor in
        await box.value?.handle(event)
      }
    }
  }

  private func handle(_ event: WalletEvent) async {
    switch event {
    case .historyUpdated:
            self.transactions = await manager.history.fetchAll()
    case .proofsUpdated(let mint):
      if let arr = try? await manager.proofService.availableProofs(mint: mint) {
        proofsByMint[mint.absoluteString] = arr
      }
      // Persistence is owned by a single writer at the composition root
      // (CashuBootstrap.saveWallet), which writes from the repository source of
      // truth with file protection. Writing here too raced on the same file.
    case .quoteUpdated(let q):
      if let idx = quotes.firstIndex(where: { $0.id == q.id }) { quotes[idx] = q }
      else { quotes.append(q) }
    case .mintSynced:
      break
    case .quoteExecuted:
        break
    }
  }
    
    // MARK: - Manual refresh helpers
    @MainActor
    public func refreshAll() async {
        do {
            // 1. Ask the service for ALL unspent proofs (passing nil for mint)
            // This grabs everything in the database, regardless of what the UI currently knows.
            let allProofs = try await manager.proofService.getUnspent(mint: nil)
            
            // 2. Debug Log (Check if your 2800 sats appear here)
            let total = allProofs.reduce(0) { $0 + $1.amount }
            cocoLog("📊 UI REFRESH: Loaded \(allProofs.count) proofs. Total Balance: \(total) sats")
            
            // 3. Re-group them by Mint URL
            var newMap: [String: [Proof]] = [:]
            
            for proof in allProofs {
                // We use absoluteString to group them in the UI
                let urlString = proof.mint.absoluteString
                newMap[urlString, default: []].append(proof)
            }
            
            // 4. Update the Published property
            // This triggers the UI to redraw immediately
            self.proofsByMint = newMap
            
        } catch {
            cocoLog("⚠️ UI Refresh Failed: \(error.localizedDescription)")
        }
    }
    
    public func refresh(mint: URL) async {
      if let arr = try? await manager.proofService.availableProofs(mint: mint) {
        proofsByMint[mint.absoluteString] = arr
      }
    }
}
public extension ObservableWallet {
    /// Wrapper for the Core restoration service
    @MainActor
    func scanForFunds(mint: URL, onProgress: (@Sendable (Int64) -> Void)? = nil) async throws -> Int {
        // Use the library service we just built
        let restorer = WalletRestorationService(manager: self.manager)
        
        let count = try await restorer.restoreFunds(mintURL: mint, progress: onProgress)
        
        // Refresh the UI state automatically after scanning
        await self.refreshAll()
        
        return count
    }
}

