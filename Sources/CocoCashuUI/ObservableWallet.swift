struct WalletStoredProof: Codable {
    let amount: Int64
    let mint: String
    let secretBase64: String
    let C: String
    let keysetId: String
}

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
      persistProofs()
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
            print("📊 UI REFRESH: Loaded \(allProofs.count) proofs. Total Balance: \(total) sats")
            
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
            print("⚠️ UI Refresh Failed: \(error.localizedDescription)")
        }
    }
    
    public func refresh(mint: URL) async {
      if let arr = try? await manager.proofService.availableProofs(mint: mint) {
        proofsByMint[mint.absoluteString] = arr
      }
    }

    private func persistProofs() {
      let all: [WalletStoredProof] = proofsByMint.flatMap { (mintStr, proofs) in
        proofs.map { proof in
          WalletStoredProof(
            amount: proof.amount,
            mint: mintStr,
            secretBase64: proof.secret.base64EncodedString(),
            C: proof.C,
            keysetId: proof.keysetId
          )
        }
      }

      let url = Self.storeURL()
      let encoder = JSONEncoder()
      do {
        let data = try encoder.encode(all)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
      } catch {
        print("ObservableWallet persistProofs error:", error)
      }
    }

    private static func storeURL() -> URL {
      let fm = FileManager.default
      let base: URL
      if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true) {
        base = appSupport
      } else {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
      }
      let dir = base.appendingPathComponent("CocoCashuWallet", isDirectory: true)
      return dir.appendingPathComponent("proofs.json")
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

