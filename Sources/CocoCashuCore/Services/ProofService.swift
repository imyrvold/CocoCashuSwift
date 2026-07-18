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
  /// The timeout must exceed the longest possible network operation (melt requests
  /// run up to 120s) with margin — an in-flight operation whose reservation expires
  /// would have its inputs released and double-spendable by a concurrent operation.
  public func reserve(amount: Int64, mint: MintURL, timeout: TimeInterval = 300) async throws -> [Proof] {
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

  /// Park proofs whose melt outcome is unknown. They stop counting toward the
  /// spendable balance until `reconcilePending` resolves them via NUT-07.
  public func markPending(_ ids: [ProofId], mint: MintURL) async throws {
    try await proofs.updateState(ids: ids, to: .pending)
    events.emit(.proofsUpdated(mint: mint))
  }

  /// Proofs currently parked as `.pending` (awaiting NUT-07 reconciliation).
  public func pendingProofs(mint: MintURL? = nil) async throws -> [Proof] {
    try await proofs.fetchPending(mint: mint)
  }

  /// Proofs currently `.reserved` by an in-flight operation. Exposed so the
  /// persistence layer can save them — an app kill mid-operation must not erase
  /// them from disk (they are still money until the mint says otherwise).
  public func reservedProofs(mint: MintURL? = nil) async throws -> [Proof] {
    try await proofs.fetchReserved(mint: mint)
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
