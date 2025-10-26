import Foundation

public typealias MintURL = URL
public typealias ProofId = UUID
public typealias QuoteId = UUID
public typealias TokenId = UUID


public enum ProofState: String, Codable, Sendable {
  case unspent, reserved, spent
}

// MARK: - NUT-04 Blinding DTOs and Protocols

/// Blinded output to request a blind signature from the mint (NUT-04)
/// Send in the POST /v1/mint/bolt11 body as: { "amount": <sats>, "B_": "<hex>" }
public struct BlindedOutput: Codable, Sendable, Hashable {
  public let amount: Int64
  public let B_: String
  public init(amount: Int64, B_: String) { self.amount = amount; self.B_ = B_ }
}

/// Blind signature (response) from the mint (NUT-04)
/// Mints may return either `C_` or legacy `C` field name.
public struct BlindSignatureDTO: Codable, Sendable, Hashable {
  public let amount: Int64
  public let C_: String?
  public let C: String?
  public init(amount: Int64, C_: String? = nil, C: String? = nil) { self.amount = amount; self.C_ = C_; self.C = C }
}

/// Abstraction over the blinding / unblinding operations required by NUT-04.
/// Your app should provide a concrete implementation (e.g., backed by CocoCashuCore crypto) and
/// inject it into the coordinator that executes a paid mint quote.
public protocol BlindingEngine: Sendable {
  /// Choose a denomination split for a given amount (e.g., 10 -> [8,2])
  func planOutputs(amount: Int64, mint: MintURL) async throws -> [Int64]

  /// Produce blinded outputs (B_) for the chosen parts and remember the blinding secrets internally
  /// so that `unblind` below can reconstruct spendable Proofs for the corresponding signatures.
  func blind(parts: [Int64], mint: MintURL) async throws -> [BlindedOutput]

  /// Unblind the returned blind signatures (C_/C) into Proofs using the secrets referenced by the
  /// `parts` passed previously to `blind`. Implementations must match outputs to signatures by index or amount.
  func unblind(signatures: [BlindSignatureDTO], for parts: [Int64], mint: MintURL) async throws -> [Proof]
}

/// A placeholder engine that throws until a real implementation is provided.
/// Useful to keep the project compiling while wiring up the coordinator.
public struct NoopBlindingEngine: BlindingEngine {
  public init() {}
  public func planOutputs(amount: Int64, mint: MintURL) async throws -> [Int64] { return [] }
  public func blind(parts: [Int64], mint: MintURL) async throws -> [BlindedOutput] { throw NSError(domain: "BlindingEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "No blinding implementation configured"]) }
  public func unblind(signatures: [BlindSignatureDTO], for parts: [Int64], mint: MintURL) async throws -> [Proof] { throw NSError(domain: "BlindingEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "No unblinding implementation configured"]) }
}

// MARK: - Keyset & CocoBlindingEngine scaffolding

/// Minimal representation of a mint keyset. In practice, the mint exposes /v1/keys
/// mapping denominations (amounts) to public keys used for blind signatures.
public struct Keyset: Codable, Sendable, Hashable {
  public let id: String
  public let keys: [Int64: String] // amount -> pubkey (hex or bech)
  public init(id: String, keys: [Int64: String]) { self.id = id; self.keys = keys }
}

/// A configurable blinding engine that you can back with CocoCashuCore’s crypto.
/// This scaffolding compiles and handles output planning; wire the two TODOs to finish NUT-04.
public struct CocoBlindingEngine: BlindingEngine {
  public typealias KeysetFetcher = @Sendable (MintURL) async throws -> Keyset

  private let fetchKeyset: KeysetFetcher

  /// Create with a closure that fetches the current keyset for a mint (e.g. RealMintAPI /v1/keys)
  public init(fetchKeyset: @escaping KeysetFetcher) {
    self.fetchKeyset = fetchKeyset
  }

  /// Simple power-of-two split (e.g., 10 -> [8,2]). Replace if you have a smarter splitter.
  public func planOutputs(amount: Int64, mint: MintURL) async throws -> [Int64] {
    precondition(amount > 0, "amount must be > 0")
    var x = amount
    var parts: [Int64] = []
    var p: Int64 = 1
    while p <= x { p <<= 1 }
    p >>= 1
    while x > 0 {
      if p <= x { parts.append(p); x -= p }
      p >>= 1
    }
    return parts
  }

  // Storage for blinding handles (secrets/r) keyed by (mint, amount) order for this session.
  // In a production engine you’d persist per-quote context to guarantee order matching.
  private actor Store {
    private var lastParts: [Int64] = []
    private var lastMint: MintURL? = nil
    private var handles: [Int64: (secret: Data, r: Data)] = [:]

    func setHandle(_ amount: Int64, secret: Data, r: Data) { handles[amount] = (secret, r) }
    func handle(for amount: Int64) -> (secret: Data, r: Data)? { handles[amount] }

    func setContext(parts: [Int64], mint: MintURL) {
      lastParts = parts
      lastMint = mint
    }
    func context() -> (mint: MintURL?, parts: [Int64]) { (lastMint, lastParts) }
  }
  private let store = Store()

  public func blind(parts: [Int64], mint: MintURL) async throws -> [BlindedOutput] {
    // Fetch keyset (not used in the placeholder math but required for real blinding)
    _ = try await fetchKeyset(mint)

    // TODO: Replace placeholder with real EC blind: B_ = r*G + H(secret)*PubKey(amount)
    // Generate a random secret and r for each part and keep them for unblinding later.
    let outputs: [BlindedOutput] = parts.map { amt in
      let secret = randomBytes(32)
      let r = randomBytes(32)
      let B_placeholder = (secret + r).map { String(format: "%02x", $0) }.joined()
      Task { await store.setHandle(amt, secret: secret, r: r) }
      return BlindedOutput(amount: amt, B_: B_placeholder)
    }
    await store.setContext(parts: parts, mint: mint)
    return outputs
  }

  public func unblind(signatures: [BlindSignatureDTO], for parts: [Int64], mint: MintURL) async throws -> [Proof] {
    // TODO: Replace placeholder with real EC unblind using r and the mint pubkey for each amount.
    // Here we just sanity-check the order and return synthetic Proofs to keep the app wiring complete.
    let ctx = await store.context()
    let savedMint = ctx.mint
    let savedParts = ctx.parts
    guard savedMint == mint, savedParts == parts else {
      throw NSError(domain: "CocoBlindingEngine", code: -10, userInfo: [NSLocalizedDescriptionKey: "Blinding context not found or mismatched order"])
    }
    var results: [Proof] = []
    for (i, sig) in signatures.enumerated() {
      guard i < parts.count, sig.amount == parts[i] else {
        throw NSError(domain: "CocoBlindingEngine", code: -11, userInfo: [NSLocalizedDescriptionKey: "Signature/output amount mismatch"])
      }
      // In real implementation: recover secret from handle and unblind C_/C to a valid signature over secret.
      // Placeholder: use the stored secret as the proof secret so UI can progress locally.
      if let handle = await store.handle(for: parts[i]) {
        results.append(Proof(amount: parts[i], mint: mint, secret: handle.secret))
      } else {
        throw NSError(domain: "CocoBlindingEngine", code: -12, userInfo: [NSLocalizedDescriptionKey: "Missing blinding handle for part \(parts[i])"])
      }
    }
    return results
  }
}

// MARK: - Small helpers
private func randomBytes(_ count: Int) -> Data {
  var bytes = [UInt8](repeating: 0, count: count)
  _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
  return Data(bytes)
}
