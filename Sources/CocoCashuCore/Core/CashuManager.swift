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
}
