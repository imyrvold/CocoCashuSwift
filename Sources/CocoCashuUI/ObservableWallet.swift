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
// MARK: - Multi-mint balances (display state derived from proofsByMint)

public extension ObservableWallet {
    struct MintBalance: Identifiable, Sendable {
        public var id: String { url }
        public let host: String
        public let balance: Int64
        public let url: String
    }

    /// Unspent balance summed across every mint the wallet holds proofs at.
    var totalBalance: Int64 {
        proofsByMint.values.reduce(0) { total, proofs in
            total + proofs.filter { $0.state == .unspent }.map(\.amount).reduce(0, +)
        }
    }

    /// Per-mint balances (host + sats), largest first, zero balances omitted.
    var mintBalances: [MintBalance] {
        proofsByMint.compactMap { (urlString, proofs) in
            let bal = proofs.filter { $0.state == .unspent }.map(\.amount).reduce(0, +)
            guard bal > 0 else { return nil }
            let host = URL(string: urlString)?.host ?? urlString
            return MintBalance(host: host, balance: bal, url: urlString)
        }
        .sorted { $0.balance > $1.balance }
    }
}

// MARK: - Restore scanning

public extension ObservableWallet {
    /// Wrapper for the Core restoration service (single mint).
    @MainActor
    func scanForFunds(mint: URL, onProgress: (@Sendable (Int64) -> Void)? = nil) async throws -> Int {
        let restorer = WalletRestorationService(manager: self.manager)
        let count = try await restorer.restoreFunds(mintURL: mint, progress: onProgress)
        await self.refreshAll()
        return count
    }

    /// Scan every mint the wallet knows, plus an optional user-entered mint URL
    /// (needed on a fresh restore, where the wallet knows only the default mint).
    /// Throws only on an invalid/insecure extra URL; per-mint scan failures are
    /// reported in the outcomes instead of aborting the sweep.
    @MainActor
    func scanAllMints(extraMintString: String? = nil) async throws -> [MintScanOutcome] {
        var extras: [URL] = []
        if let raw = extraMintString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let url = URL(string: raw) else {
                throw CashuError.protocolError("'\(raw)' is not a valid mint URL")
            }
            try RealMintAPI.requireSecure(url)
            extras.append(url)
        }
        let outcomes = await manager.scanAllMints(extra: extras)
        await self.refreshAll()
        return outcomes
    }
}

