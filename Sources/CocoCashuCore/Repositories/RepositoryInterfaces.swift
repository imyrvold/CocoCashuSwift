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

public protocol CounterRepository: Sendable {
  func nextCounter(key: String) async throws -> Int64
}
