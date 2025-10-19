import Foundation

public struct Token: Codable, Sendable, Identifiable, Hashable {
  public let id: TokenId
  public let mint: MintURL
  public let amount: Int64
  public let proofs: [ProofId]

  public init(id: TokenId = .init(), mint: MintURL, amount: Int64, proofs: [ProofId]) {
    self.id = id; self.mint = mint; self.amount = amount; self.proofs = proofs
  }
}
