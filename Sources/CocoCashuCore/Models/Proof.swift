import Foundation

public struct Proof: Codable, Sendable, Identifiable, Hashable {
  public let id: ProofId
  public let amount: Int64
  public let mint: MintURL
  public let secret: Data
    public let C: String          // <--- ADD THIS
      public let keysetId: String   // <--- ADD THIS
  public var state: ProofState
  public let createdAt: Date
  public var reservedUntil: Date?

  public init(
    id: ProofId = .init(),
    amount: Int64,
    mint: MintURL,
    secret: Data,
    C: String,                  // <--- ADD PARAMS
        keysetId: String,           // <--- ADD PARAMS
    state: ProofState = .unspent,
    createdAt: Date = .now,
    reservedUntil: Date? = nil
  ) {
    self.id = id; self.amount = amount; self.mint = mint
    self.secret = secret
      self.C = C                  // <--- ASSIGN
          self.keysetId = keysetId    // <--- ASSIGN
          self.state = state
      self.createdAt = createdAt; self.reservedUntil = reservedUntil
  }
}
