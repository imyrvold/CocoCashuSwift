// InMemoryRepositories.swift
import Foundation

public actor InMemoryProofRepository: ProofRepository {
  private var store: [ProofId: Proof] = [:]

  public init() {}

  public func insert(_ proof: Proof) async throws { store[proof.id] = proof }
  public func insertMany(_ proofs: [Proof]) async throws {
    for p in proofs { store[p.id] = p }
  }
  public func fetchUnspent(mint: MintURL?) async throws -> [Proof] {
    store.values.filter { $0.state == .unspent && (mint == nil || $0.mint == mint!) }
  }
  public func updateState(ids: [ProofId], to state: ProofState) async throws {
    for id in ids { if var p = store[id] { p.state = state; store[id] = p } }
  }
  public func reserve(ids: [ProofId], until: Date) async throws {
    for id in ids { if var p = store[id] { p.reservedUntil = until; p.state = .reserved; store[id] = p } }
  }
  public func delete(ids: [ProofId]) async throws { ids.forEach { store.removeValue(forKey: $0) } }
}

public actor InMemoryMintRepository: MintRepository {
  private var store: [String: Mint] = [:]
  public init() {}
  public func upsert(_ mint: Mint) async throws { store[mint.id] = mint }
  public func fetchAll() async throws -> [Mint] { Array(store.values) }
  public func fetch(by url: MintURL) async throws -> Mint? { store[url.absoluteString] }
}

public actor InMemoryQuoteRepository: QuoteRepository {
  private var store: [QuoteId: Quote] = [:]
  public init() {}
  public func insert(_ q: Quote) async throws { store[q.id] = q }
  public func update(_ q: Quote) async throws { store[q.id] = q }
  public func fetch(id: QuoteId) async throws -> Quote? { store[id] }
  public func fetchPending(mint: MintURL?) async throws -> [Quote] {
    store.values.filter { $0.status == .pending && (mint == nil || $0.mint == mint!) }
  }
}

public actor InMemoryCounterRepository: CounterRepository {
  private var counters: [String: Int64] = [:]
  public init() {}
  public func nextCounter(key: String) async throws -> Int64 {
    let next = (counters[key] ?? 0) + 1; counters[key] = next; return next
  }
}
