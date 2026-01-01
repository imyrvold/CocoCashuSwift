// ProofService.swift
import Foundation

public actor ProofService {
  private let proofs: ProofRepository
  private let events: EventBus

  public init(proofs: ProofRepository, events: EventBus) {
    self.proofs = proofs; self.events = events
  }

  public func availableProofs(mint: MintURL) async throws -> [Proof] {
    try await proofs.fetchUnspent(mint: mint)
  }

  /// Reserve proofs for spending. Caller should cancel/update on failure.
  public func reserve(amount: Int64, mint: MintURL, timeout: TimeInterval = 60) async throws -> [Proof] {
    var total: Int64 = 0
    let unspent = try await proofs.fetchUnspent(mint: mint).sorted { $0.amount > $1.amount }
    var toUse: [Proof] = []
    for p in unspent where total < amount {
      toUse.append(p); total += p.amount
    }
    guard total >= amount else { throw CashuError.insufficientFunds }
    let until = Date(timeIntervalSinceNow: timeout)
    try await proofs.reserve(ids: toUse.map(\.id), until: until)
    events.emit(.proofsUpdated(mint: mint))
    return toUse
  }

  public func markSpent(_ ids: [ProofId], mint: MintURL) async throws {
    try await proofs.updateState(ids: ids, to: .spent)
    events.emit(.proofsUpdated(mint: mint))
  }

  public func addNew(_ proofsToAdd: [Proof]) async throws {
    try await proofs.insertMany(proofsToAdd)
    if let m = proofsToAdd.first?.mint { events.emit(.proofsUpdated(mint: m)) }
  }

  public func spend(amount: Int64, from mint: MintURL) async throws {
    // 1) Pick largest-first unspent proofs to cover the amount
    var total: Int64 = 0
    let unspent = try await proofs.fetchUnspent(mint: mint).sorted { $0.amount > $1.amount }
    var toUse: [Proof] = []
    for p in unspent where total < amount {
      toUse.append(p)
      total += p.amount
    }
    guard total >= amount else { throw CashuError.insufficientFunds }

    // 2) Mark selected proofs as spent
    try await proofs.updateState(ids: toUse.map(\.id), to: .spent)
    events.emit(.proofsUpdated(mint: mint))

    // 3) Create local change proof if needed (total - amount)
    let change = total - amount
    if change > 0 {
      let changeProof = Proof(amount: change, mint: mint, secret: Data(), C: "", keysetId: "")
      try await proofs.insert(changeProof)
      events.emit(.proofsUpdated(mint: mint))
    }
  }
    
    public func remove(_ proofsToRemove: [Proof]) async throws {
        try await proofs.delete(ids: proofsToRemove.map(\.id))
    }
    
    /// Unreserves proofs, making them available for spending again immediately.
      public func unreserve(_ ids: [ProofId], mint: MintURL) async throws {
        try await proofs.updateState(ids: ids, to: .unspent)
        events.emit(.proofsUpdated(mint: mint))
      }
    
    /// Returns unspent proofs. If mint is nil, returns unspent proofs for ALL mints.
    public func getUnspent(mint: MintURL? = nil) async throws -> [Proof] {
        try await proofs.fetchUnspent(mint: mint)
    }
}
