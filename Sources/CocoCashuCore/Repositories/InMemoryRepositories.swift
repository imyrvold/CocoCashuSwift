// InMemoryRepositories.swift
import Foundation

public actor InMemoryProofRepository: ProofRepository {
    // CHANGE: Key is now the Signature (C), not the random ID.
    // This physically prevents duplicates.
    private var store: [String: Proof] = [:]
    
    public init() {}
    
    private func areSameMint(_ u1: URL, _ u2: URL) -> Bool {
        let s1 = u1.absoluteString.trimmingCharacters(in: .init(charactersIn: "/"))
        let s2 = u2.absoluteString.trimmingCharacters(in: .init(charactersIn: "/"))
        return s1 == s2
    }
    
    public func insert(_ proof: Proof) async throws {
        // Always overwrite based on C (Signature)
        store[proof.C] = proof
    }
    
    public func insertMany(_ proofs: [Proof]) async throws {
        for p in proofs {
            if let existing = store[p.C] {
                // TOKEN EXISTS: Merge/Update it
                var updated = existing
                
                // 1. Force Metadata Update (Fixes URL/Keyset issues)
                updated.mint = p.mint
                updated.keysetId = p.keysetId
                
                // 2. Revive if newly found as unspent
                if updated.state != .unspent && p.state == .unspent {
                    cocoLog("✨ Reviving spent token: \(p.amount) sats")
                    updated.state = .unspent
                } else {
                    // It's already fine, just updated metadata
                    cocoLog("🔄 Synced duplicate token: \(p.amount) sats")
                }
                
                store[p.C] = updated
                
            } else {
                // NEW TOKEN
                store[p.C] = p
                cocoLog("✅ Added new token: \(p.amount) sats")
            }
        }
    }
    
    public func fetchUnspent(mint: MintURL?) async throws -> [Proof] {
        releaseExpiredReservations()
        if let m = mint {
            return store.values.filter {
                $0.state == .unspent && areSameMint($0.mint, m)
            }
        }
        return store.values.filter { $0.state == .unspent }
    }

    /// Enforce the reservation timeout: a proof whose `reservedUntil` has passed
    /// was reserved by an operation that died without cleaning up — release it so
    /// funds don't stay stranded forever. (`.pending` proofs are NOT touched; they
    /// were knowingly submitted to the mint and only NUT-07 may release them.)
    private func releaseExpiredReservations() {
        let now = Date()
        for (key, proof) in store where proof.state == .reserved {
            if let until = proof.reservedUntil, until < now {
                var p = proof
                p.state = .unspent
                p.reservedUntil = nil
                store[key] = p
            }
        }
    }

    public func fetchPending(mint: MintURL?) async throws -> [Proof] {
        if let m = mint {
            return store.values.filter {
                $0.state == .pending && areSameMint($0.mint, m)
            }
        }
        return store.values.filter { $0.state == .pending }
    }

    public func fetchReserved(mint: MintURL?) async throws -> [Proof] {
        if let m = mint {
            return store.values.filter {
                $0.state == .reserved && areSameMint($0.mint, m)
            }
        }
        return store.values.filter { $0.state == .reserved }
    }

    public func updateState(ids: [ProofId], to state: ProofState) async throws {
        // Since we changed the key to C, we need to iterate to find by ID
        // (Performance note: In a real DB, you'd index ID too. For memory, this is fine.)
        for id in ids {
            if let found = store.values.first(where: { $0.id == id }) {
                var p = found
                p.state = state
                store[p.C] = p
            }
        }
    }
    
    public func reserve(ids: [ProofId], until: Date) async throws {
        for id in ids {
            if let found = store.values.first(where: { $0.id == id }) {
                var p = found
                p.reservedUntil = until
                p.state = .reserved
                store[p.C] = p
            }
        }
    }
    
    public func delete(ids: [ProofId]) async throws {
        for id in ids {
            if let found = store.values.first(where: { $0.id == id }) {
                store.removeValue(forKey: found.C)
            }
        }
    }
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

/// In-memory NUT-13 counter — **for tests only**. It resets to 0 every launch, so
/// using it in production GUARANTEES derivation-index reuse (same secret + blinding
/// factor derived twice → the mint rejects the duplicate, or funds become
/// ambiguous). Production code must use `FileCounterRepository`.
public actor InMemoryCounterRepository: CounterRepository {
  private var counters: [String: Int64] = [:]
  public init() {}
  public func current(key: String) async throws -> Int64 { counters[key] ?? 0 }
  public func reserve(key: String, count: Int) async throws -> Int64 {
    let start = counters[key] ?? 0
    counters[key] = start + Int64(count)
    return start
  }
  public func advance(key: String, to minimum: Int64) async throws {
    counters[key] = max(counters[key] ?? 0, minimum)
  }
}

/// Disk-backed counter repository that persists derivation indices atomically.
/// Use this in production so NUT-13 indices survive app restarts and are never reused.
public actor FileCounterRepository: CounterRepository {
  private let url: URL
  private var counters: [String: Int64]

  public init(url: URL) {
    self.url = url
    if let data = try? Data(contentsOf: url),
       let decoded = try? JSONDecoder().decode([String: Int64].self, from: data) {
      self.counters = decoded
    } else {
      self.counters = [:]
    }
  }

  public func current(key: String) async throws -> Int64 { counters[key] ?? 0 }

  public func reserve(key: String, count: Int) async throws -> Int64 {
    let start = counters[key] ?? 0
    counters[key] = start + Int64(count)
    try persist()
    return start
  }

  public func advance(key: String, to minimum: Int64) async throws {
    let current = counters[key] ?? 0
    guard minimum > current else { return }
    counters[key] = minimum
    try persist()
  }

  private func persist() throws {
    let data = try JSONEncoder().encode(counters)
    var options: Data.WritingOptions = [.atomic]
    #if os(iOS)
    options.insert(.completeFileProtection)
    #endif
    try data.write(to: url, options: options)
  }
}
