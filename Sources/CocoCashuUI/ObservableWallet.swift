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
    case .quoteUpdated(let q):
      if let idx = quotes.firstIndex(where: { $0.id == q.id }) { quotes[idx] = q }
      else { quotes.append(q) }
    case .mintSynced:
      break
    case .quoteExecuted:
        break
    }
  }
}
