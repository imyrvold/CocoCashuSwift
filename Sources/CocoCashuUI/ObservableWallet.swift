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

  public let manager: CashuManager

  public init(manager: CashuManager) {
    self.manager = manager
    let box = WeakBox(self)
    manager.events.subscribe { event in
      Task { @MainActor in
        await box.value?.handle(event)
      }
    }
  }

  private func handle(_ event: WalletEvent) async {
    switch event {
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
    public func refreshAll() async {
      // Refresh all mints currently shown in the UI
      let knownMints = proofsByMint.keys.compactMap { URL(string: $0) }
      for mint in knownMints {
        if let arr = try? await manager.proofService.availableProofs(mint: mint) {
          proofsByMint[mint.absoluteString] = arr
        }
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
