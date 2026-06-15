// RepositoryInterfaces.swift
import Foundation

public protocol ProofRepository: Sendable {
  func insert(_ proof: Proof) async throws
  func insertMany(_ proofs: [Proof]) async throws
  func fetchUnspent(mint: MintURL?) async throws -> [Proof]
  func updateState(ids: [ProofId], to state: ProofState) async throws
  func reserve(ids: [ProofId], until: Date) async throws
  func delete(ids: [ProofId]) async throws
}

public protocol MintRepository: Sendable {
  func upsert(_ mint: Mint) async throws
  func fetchAll() async throws -> [Mint]
  func fetch(by url: MintURL) async throws -> Mint?
}

public protocol QuoteRepository: Sendable {
  func insert(_ q: Quote) async throws
  func update(_ q: Quote) async throws
  func fetch(id: QuoteId) async throws -> Quote?
  func fetchPending(mint: MintURL?) async throws -> [Quote]
}

/// Tracks the NUT-13 deterministic-secret derivation index per keyset scope.
/// Indices start at 0 and must NEVER be reused, otherwise the same secret is
/// derived twice and the mint rejects the duplicate (or funds become ambiguous).
/// Implementations must persist the advance durably before returning from `reserve`.
public protocol CounterRepository: Sendable {
  /// The next unused derivation index for a scope (0 if the scope is new).
  func current(key: String) async throws -> Int64
  /// Atomically reserve `count` consecutive indices and return the first one,
  /// persisting the advance before returning.
  func reserve(key: String, count: Int) async throws -> Int64
}
