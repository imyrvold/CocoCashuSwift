// InMemoryRepositories.swift
import Foundation

/// In-memory proof repository (tests, previews). Production wallets should use
/// `FileProofRepository` so balances survive relaunch. All bookkeeping lives in
/// the shared `ProofStore` so the two repositories cannot diverge.
public actor InMemoryProofRepository: ProofRepository {
    private var store = ProofStore()

    public init() {}

    public func insert(_ proof: Proof) async throws { store.insert(proof) }
    public func insertMany(_ proofs: [Proof]) async throws { store.insertMany(proofs) }

    public func fetchUnspent(mint: MintURL?) async throws -> [Proof] {
        store.releaseExpired(now: Date())
        return store.proofs(state: .unspent, mint: mint)
    }
    public func fetchPending(mint: MintURL?) async throws -> [Proof] { store.proofs(state: .pending, mint: mint) }
    public func fetchReserved(mint: MintURL?) async throws -> [Proof] { store.proofs(state: .reserved, mint: mint) }

    public func updateState(ids: [ProofId], to state: ProofState) async throws { store.updateState(ids: ids, to: state) }
    public func reserve(ids: [ProofId], until: Date) async throws { store.reserve(ids: ids, until: until) }
    public func delete(ids: [ProofId]) async throws { store.delete(ids: ids) }
}

/// Disk-backed proof repository: the single source of truth for stored money.
/// Loads on init and persists after every mutation with the same atomicity and
/// file-protection guarantees as `FileCounterRepository`. This replaces the
/// app-side hand-rolled persistence (event-driven save + `StoredProof`
/// translation) that caused the double-writer race and the reserved/pending
/// persistence bugs.
public actor FileProofRepository: ProofRepository {
    private let url: URL
    private var store: ProofStore

    public init(url: URL) {
        self.url = url
        self.store = Self.load(from: url)
    }

    // MARK: Loading & migration

    private static func load(from url: URL) -> ProofStore {
        guard let data = try? Data(contentsOf: url) else { return ProofStore() }
        // Current format: an array of Proof.
        if let proofs = try? JSONDecoder().decode([Proof].self, from: data) {
            return ProofStore(recover(proofs))
        }
        // Legacy format written by the app's StoredProof/WalletStoredProof. Decode
        // and convert so an upgrading user's balance is preserved (the two JSON
        // shapes are mutually exclusive, so this only triggers on real old files).
        if let legacy = try? JSONDecoder().decode([LegacyStoredProof].self, from: data) {
            return ProofStore(recover(legacy.compactMap { $0.toProof() }))
        }
        return ProofStore()
    }

    /// A proof persisted as `.reserved` belonged to an operation the app died
    /// mid-way through; its outcome is unknown, so load it as `.pending` for
    /// NUT-07 reconciliation rather than treating it as spendable.
    private static func recover(_ proofs: [Proof]) -> [Proof] {
        proofs.map { p in
            guard p.state == .reserved else { return p }
            var c = p
            c.state = .pending
            c.reservedUntil = nil
            return c
        }
    }

    // MARK: Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(store.persistable) else { return }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: options)
    }

    // MARK: ProofRepository

    public func insert(_ proof: Proof) async throws { store.insert(proof); persist() }
    public func insertMany(_ proofs: [Proof]) async throws { store.insertMany(proofs); persist() }

    public func fetchUnspent(mint: MintURL?) async throws -> [Proof] {
        if store.releaseExpired(now: Date()) { persist() }
        return store.proofs(state: .unspent, mint: mint)
    }
    public func fetchPending(mint: MintURL?) async throws -> [Proof] { store.proofs(state: .pending, mint: mint) }
    public func fetchReserved(mint: MintURL?) async throws -> [Proof] { store.proofs(state: .reserved, mint: mint) }

    public func updateState(ids: [ProofId], to state: ProofState) async throws { store.updateState(ids: ids, to: state); persist() }
    public func reserve(ids: [ProofId], until: Date) async throws { store.reserve(ids: ids, until: until); persist() }
    public func delete(ids: [ProofId]) async throws { store.delete(ids: ids); persist() }
}

/// Legacy on-disk proof shape written by earlier app builds (CashuBootstrap's
/// `StoredProof` / ObservableWallet's `WalletStoredProof`). Kept only to migrate
/// existing wallets to the `[Proof]` format on first launch of a new build.
struct LegacyStoredProof: Decodable {
    let amount: Int64
    let mint: String
    let secretBase64: String
    let C: String
    let keysetId: String
    var state: ProofState?

    func toProof() -> Proof? {
        guard let mintURL = URL(string: mint), let secret = Data(base64Encoded: secretBase64) else { return nil }
        return Proof(amount: amount, mint: mintURL, secret: secret, C: C, keysetId: keysetId, state: state ?? .unspent)
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
