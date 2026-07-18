import Foundation
import secp256k1_bindings
import CryptoKit

public typealias MintURL = URL
public typealias ProofId = UUID
public typealias QuoteId = UUID
public typealias TokenId = UUID


/// NUT-05 melt quote settlement state.
public enum MeltState: String, Sendable {
  case unpaid, pending, paid, unknown
}

/// Outcome of a melt (`MintService.spend`). `.paid` means the Lightning payment
/// settled and inputs are finalized as spent. `.pending` means the mint accepted
/// the melt but the payment is still in flight after polling — the inputs are
/// parked and will be reconciled later; this is NOT a failure.
public enum MeltResult: Sendable {
  case paid(feePaid: Int64)
  case pending
}

public enum ProofState: String, Codable, Sendable {
  /// `pending`: inputs submitted to the mint in a melt whose outcome is unknown
  /// (timeout, mint reported PENDING, decode failure). They are NOT spendable and
  /// must be reconciled via NUT-07 checkstate before being released or finalized.
  case unspent, reserved, pending, spent
}

// MARK: - NUT-04 Blinding DTOs and Protocols

/// Blinded output to request a blind signature from the mint (NUT-04)
/// Send in the POST /v1/mint/bolt11 body as: { "amount": <sats>, "B_": "<hex>" }
public struct BlindedOutput: Sendable, Hashable {
    public let amount: Int64
    public let B_: String
    public let id: String
    
    // New: Carry the keys locally. Optional so we don't break existing code.
    public let secret: Data?
    public let r: Data?

    public init(amount: Int64, B_: String, id: String, secret: Data? = nil, r: Data? = nil) {
        self.amount = amount
        self.B_ = B_
        self.id = id
        self.secret = secret
        self.r = r
    }
}

/// NUT-12 discrete-log-equality proof accompanying a blind signature. `e` and `s`
/// let the wallet verify the mint signed with the same key it publishes — so the
/// mint cannot tag/deanonymize a user with a per-user signing key. `r` (the
/// blinding factor) is present only on proofs carried inside a token, for the
/// receiver's own verification.
public struct DLEQProof: Codable, Sendable, Hashable {
    public let e: String
    public let s: String
    public let r: String?
    public init(e: String, s: String, r: String? = nil) { self.e = e; self.s = s; self.r = r }
}

/// Blind signature (response) from the mint (NUT-04)
/// Mints may return either `C_` or legacy `C` field name.
public struct BlindSignatureDTO: Codable, Sendable, Hashable {
  public let id: String?
  public let amount: Int64
  public let C_: String?
  public let C: String?
  public let dleq: DLEQProof?
    public init(amount: Int64, C_: String? = nil, C: String? = nil, id: String? = nil, dleq: DLEQProof? = nil) { self.amount = amount; self.C_ = C_; self.C = C; self.id = id; self.dleq = dleq }

    enum CodingKeys: String, CodingKey {
        case id
        case amount
        case C_
        case C
        case dleq
    }
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
    func unblind(signatures: [BlindSignatureDTO], for inputs: [BlindedOutput], mint: MintURL) async throws -> [Proof]
    func deriveForRestore(indices: [UInt32], mint: MintURL, keysetID: String) async throws -> (outputs: [BlindedOutput], secrets: [UInt32: (Data, Data)])

    /// NUT-12: verify a blind signature's DLEQ proof against the mint's public key
    /// for that denomination. Returns true only when the proof is present AND valid.
    /// A missing proof returns false (caller decides whether to require it); a
    /// present-but-invalid proof must cause the signature to be rejected.
    func verifyDLEQ(blindedMessage B_: String, blindSignature C_: String, mintPubKey A: String, e: String, s: String) async -> Bool
}

// MARK: - Keyset & CocoBlindingEngine scaffolding

/// Minimal representation of a mint keyset. In practice, the mint exposes /v1/keys
/// mapping denominations (amounts) to public keys used for blind signatures.
public struct Keyset: Codable, Sendable, Hashable {
  public let id: String
  public let keys: [Int64: String] // amount -> pubkey (hex or bech)
  public let inputFeePPK: Int64 // NUT-02: fee per input in parts per thousand (ppk)
  
  public init(id: String, keys: [Int64: String], inputFeePPK: Int64 = 0) {
    self.id = id
    self.keys = keys
    self.inputFeePPK = inputFeePPK
  }
  
  /// Calculate the fee for a given number of inputs based on input_fee_ppk
  /// Formula: ceil((numInputs * inputFeePPK) / 1000)
  public func calculateFee(forInputCount numInputs: Int) -> Int64 {
    guard inputFeePPK > 0 else { return 0 }
    let rawFee = Int64(numInputs) * inputFeePPK
    return (rawFee + 999) / 1000 // Ceiling division
  }

  /// NUT-02 version-00 keyset ID derivation: sort keys by amount ascending,
  /// concatenate the compressed pubkey bytes, SHA256, take the first 14 hex
  /// chars, prefix "00". Returns nil if any amount or pubkey fails to parse.
  ///
  /// Takes the RAW `amount-string → pubkey-hex` map exactly as the mint serves
  /// it. This must NOT be computed from the parsed `[Int64: String]` map: mints
  /// routinely publish 64 denominations up to 2^63 (9223372036854775808), which
  /// overflows Int64 — that key would silently drop out and the derived ID would
  /// mismatch every honest 64-key mint. Amounts are sorted as UInt64.
  ///
  /// Recomputing this over the keys a mint serves — and comparing to the ID the
  /// mint claims — prevents a malicious mint from handing different users
  /// different keys under the same advertised keyset ID (a deanonymization
  /// primitive: proofs get signed by per-user keys).
  public static func deriveV00Id(rawKeys: [String: String]) -> String? {
    var parsed: [(amount: UInt64, keyBytes: Data)] = []
    parsed.reserveCapacity(rawKeys.count)
    for (amountStr, keyHex) in rawKeys {
      guard let amount = UInt64(amountStr), let keyBytes = Data(hex: keyHex) else { return nil }
      parsed.append((amount, keyBytes))
    }
    var concatenated = Data()
    for entry in parsed.sorted(by: { $0.amount < $1.amount }) {
      concatenated.append(entry.keyBytes)
    }
    let digest = SHA256.hash(data: concatenated)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "00" + hex.prefix(14)
  }

  /// Verify a claimed keyset ID against the RAW keys a mint served (NUT-02).
  /// Only version-00 IDs are currently checkable (version-01 IDs hash the
  /// unit/fee/expiry fields, which this model does not carry yet); other
  /// versions return true (not checked).
  public static func isValidV00Id(_ id: String, rawKeys: [String: String]) -> Bool {
    guard id.hasPrefix("00"), id.count == 16 else { return true } // not a v00 id — skip
    return deriveV00Id(rawKeys: rawKeys) == id.lowercased()
  }
}

// MARK: - Small helpers
private func randomBytes(_ count: Int) -> Data {
  var bytes = [UInt8](repeating: 0, count: count)
  _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
  return Data(bytes)
}

/// Represents a Proof sent to the mint for checking/spending (NUT-00)
public struct ProofDTO: Codable, Sendable {
    public let amount: Int64
    public let secret: String
    public let C: String
    public let id: String
    
    public init(amount: Int64, secret: String, C: String, id: String) {
        self.amount = amount
        self.secret = secret
        self.C = C
        self.id = id
    }
}

/// Represents the state of a proof (NUT-07)
public struct CheckStateDTO: Decodable, Sendable {
    public let Y: String
    public let state: CoinState
    
    public enum CoinState: String, Decodable, Sendable {
        case spent = "SPENT"
        case unspent = "UNSPENT"
        case pending = "PENDING"
    }
}
