import Foundation

public typealias MintURL = URL
public typealias ProofId = UUID
public typealias QuoteId = UUID
public typealias TokenId = UUID

public enum ProofState: String, Codable, Sendable {
  case unspent, reserved, spent
}
