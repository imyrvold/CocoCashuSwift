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
                    print("✨ Reviving spent token: \(p.amount) sats")
                    updated.state = .unspent
                } else {
                    // It's already fine, just updated metadata
                    print("🔄 Synced duplicate token: \(p.amount) sats")
                }
                
                store[p.C] = updated
                
            } else {
                // NEW TOKEN
                store[p.C] = p
                print("✅ Added new token: \(p.amount) sats")
            }
        }
    }
    
    public func fetchUnspent(mint: MintURL?) async throws -> [Proof] {
        if let m = mint {
            return store.values.filter {
                $0.state == .unspent && areSameMint($0.mint, m)
            }
        }
        return store.values.filter { $0.state == .unspent }
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

public actor InMemoryCounterRepository: CounterRepository {
  private var counters: [String: Int64] = [:]
  public init() {}
  public func nextCounter(key: String) async throws -> Int64 {
    let next = (counters[key] ?? 0) + 1; counters[key] = next; return next
  }
}
