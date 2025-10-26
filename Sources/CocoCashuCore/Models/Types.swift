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
    private var keyset: Keyset? = nil

    func setHandle(_ amount: Int64, secret: Data, r: Data) { handles[amount] = (secret, r) }
    func handle(for amount: Int64) -> (secret: Data, r: Data)? { handles[amount] }

    func setContext(parts: [Int64], mint: MintURL) {
      lastParts = parts
      lastMint = mint
    }
    func context() -> (mint: MintURL?, parts: [Int64]) { (lastMint, lastParts) }

    func setKeyset(_ ks: Keyset) { keyset = ks }
    func getKeyset() -> Keyset? { keyset }
  }
  private let store = Store()

  public func blind(parts: [Int64], mint: MintURL) async throws -> [BlindedOutput] {
    // 1) Fetch and remember keyset (for unblinding later)
    let ks = try await fetchKeyset(mint)
    await store.setKeyset(ks)

    // 2) Validate keys exist for each denomination
    for amt in parts {
      guard ks.keys[amt] != nil else { throw NSError(domain: "CocoBlindingEngine", code: -20, userInfo: [NSLocalizedDescriptionKey: "Missing mint pubkey for amount \(amt)"]) }
    }

    // 3) For each part, create secret+r and compute B_ = Y + r·G where Y = H(secret)·G
    var outs: [BlindedOutput] = []
    outs.reserveCapacity(parts.count)
    for amt in parts {
      let secret = randomBytes(32)
      let r = randomBytes(32)

      let h = sha256(secret)              // Data (32)
      var Y = try ec_pubkey_from_scalar(h) // Y = h·G
      var rG = try ec_pubkey_from_scalar(r) // r·G
      var B = try ec_combine(&Y, &rG)      // B_ = Y + r·G

      let Bbytes = try ec_serialize_pubkey(&B)
      let Bhex = Bbytes.map { String(format: "%02x", $0) }.joined()

      await store.setHandle(amt, secret: secret, r: r)
      outs.append(BlindedOutput(amount: amt, B_: Bhex))
    }

    await store.setContext(parts: parts, mint: mint)
    return outs
  }

  public func unblind(signatures: [BlindSignatureDTO], for parts: [Int64], mint: MintURL) async throws -> [Proof] {
    // Ensure context matches
    let ctx = await store.context()
    guard ctx.mint == mint, ctx.parts == parts else {
      throw NSError(domain: "CocoBlindingEngine", code: -10, userInfo: [NSLocalizedDescriptionKey: "Blinding context not found or mismatched order"])
    }

    // Get keyset (use stored, else fetch)
    var ks = await store.getKeyset()
    if ks == nil { ks = try? await fetchKeyset(mint) }
    guard let keyset = ks else { throw NSError(domain: "CocoBlindingEngine", code: -21, userInfo: [NSLocalizedDescriptionKey: "Missing keyset for unblinding"]) }

    var results: [Proof] = []
    results.reserveCapacity(parts.count)

    for (i, amt) in parts.enumerated() {
      // 1) Fetch handle
      guard let handle = await store.handle(for: amt) else {
        throw NSError(domain: "CocoBlindingEngine", code: -12, userInfo: [NSLocalizedDescriptionKey: "Missing blinding handle for part \(amt)"]) }

      // 2) Parse mint pubkey K for this denomination
      guard let pkHex = keyset.keys[amt], let pkData = Data(hex: pkHex) else {
        throw NSError(domain: "CocoBlindingEngine", code: -22, userInfo: [NSLocalizedDescriptionKey: "Invalid mint pubkey for amount \(amt)"]) }
      var K = try ec_parse_pubkey(pkData)

      // 3) Get blind signature C_ (or legacy C)
      let sig = signatures[i]
      guard let Chex = sig.C_ ?? sig.C, let Cdata = Data(hex: Chex), Cdata.count == 33 else {
        throw NSError(domain: "CocoBlindingEngine", code: -23, userInfo: [NSLocalizedDescriptionKey: "Invalid blind signature for amount \(amt)"]) }
      var Cb = try ec_parse_pubkey(Cdata)

      // 4) Compute r·K and unblind: C = C_ - r·K = C_ + (-(r·K))
      var rK = try ec_tweak_mul_pubkey(&K, handle.r)
      var neg_rK = try ec_negate(&rK)
      _ = try ec_combine(&Cb, &neg_rK) // C (unused for now)

      // 5) Build spendable Proof. You may store serialized C later if your Proof supports it.
      results.append(Proof(amount: amt, mint: mint, secret: handle.secret))
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

// MARK: - Hex decoding helper
private extension Data {
    /// Initialize Data from a hexadecimal string like "02a1b3..."
    init?(hex: String) {
        let len = hex.count / 2
        var data = Data(capacity: len)
        var index = hex.startIndex
        for _ in 0..<len {
            let next = hex.index(index, offsetBy: 2)
            guard next <= hex.endIndex else { return nil }
            let byteStr = hex[index..<next]
            guard let byte = UInt8(byteStr, radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
