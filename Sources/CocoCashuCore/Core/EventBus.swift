// EventBus.swift
import Foundation

public enum WalletEvent: Sendable {
  case proofsUpdated(mint: MintURL)
  case quoteUpdated(Quote)
  case quoteExecuted(QuoteId)
  case mintSynced(MintURL)
  case historyUpdated
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
    
    // MARK: - Swift Concurrency Support
    
    /// Exposes events as an async stream so you can loop over them with 'for await'
    public var values: AsyncStream<WalletEvent> {
        AsyncStream { continuation in
            // When a new subscription starts, we add a listener that forwards events to the stream
            self.subscribe { event in
                continuation.yield(event)
            }
            // Note: In a production app, you might want to handle unsubscription here,
            // but for a singleton-like EventBus, this simple forwarding is sufficient.
        }
    }
}
