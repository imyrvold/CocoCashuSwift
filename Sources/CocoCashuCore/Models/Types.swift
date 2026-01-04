import Foundation
import secp256k1_bindings
import CryptoKit

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

/// Blind signature (response) from the mint (NUT-04)
/// Mints may return either `C_` or legacy `C` field name.
public struct BlindSignatureDTO: Codable, Sendable, Hashable {
  public let id: String?
  public let amount: Int64
  public let C_: String?
  public let C: String?
    public init(amount: Int64, C_: String? = nil, C: String? = nil, id: String? = nil) { self.amount = amount; self.C_ = C_; self.C = C; self.id = id }
    
    enum CodingKeys: String, CodingKey {
        case id
        case amount
        case C_
        case C
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
    func verify(signature C_hex: String, secret: Data, mintPub: Data) async -> Bool
}

// MARK: - Keyset & CocoBlindingEngine scaffolding

/// Minimal representation of a mint keyset. In practice, the mint exposes /v1/keys
/// mapping denominations (amounts) to public keys used for blind signatures.
public struct Keyset: Codable, Sendable, Hashable {
  public let id: String
  public let keys: [Int64: String] // amount -> pubkey (hex or bech)
  public init(id: String, keys: [Int64: String]) { self.id = id; self.keys = keys }
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
