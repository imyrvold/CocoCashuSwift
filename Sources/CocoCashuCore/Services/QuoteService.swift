import Foundation

public actor QuoteService {
  private let quotes: QuoteRepository
  private let events: EventBus

  public init(quotes: QuoteRepository, events: EventBus) {
    self.quotes = quotes; self.events = events
  }

  public func insert(_ q: Quote) async throws {
    try await quotes.insert(q)
    events.emit(.quoteUpdated(q))
  }

  public func update(_ q: Quote) async throws {
    try await quotes.update(q)
    events.emit(.quoteUpdated(q))
  }

  public func fetch(id: QuoteId) async throws -> Quote? {
    try await quotes.fetch(id: id)
  }
}
