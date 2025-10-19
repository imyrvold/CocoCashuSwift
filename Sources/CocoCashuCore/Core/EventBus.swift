// EventBus.swift
import Foundation

public enum WalletEvent: Sendable {
  case proofsUpdated(mint: MintURL)
  case quoteUpdated(Quote)
  case mintSynced(MintURL)
}

public protocol EventSink: Sendable {
  func emit(_ event: WalletEvent)
}

public final class EventBus: @unchecked Sendable {
  private let queue = DispatchQueue(label: "cashu.eventbus", qos: .userInitiated)
  private var listeners: [@Sendable (WalletEvent) -> Void] = []

  public init() {}

  public func subscribe(_ listener: @escaping @Sendable (WalletEvent) -> Void) {
    queue.sync { listeners.append(listener) }
  }

  public func emit(_ event: WalletEvent) {
    queue.async { self.listeners.forEach { $0(event) } }
  }
}
