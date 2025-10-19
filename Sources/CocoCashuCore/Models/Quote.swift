import Foundation

public enum QuoteStatus: String, Codable, Sendable { case pending, paid, expired, failed }

public struct Quote: Codable, Sendable, Identifiable, Hashable {
  public let id: QuoteId
  public let mint: MintURL
  public let amount: Int64
  public let createdAt: Date
  public var status: QuoteStatus
  public var invoice: String?     // LN invoice (BOLT11) if using LN mints
  public var preimage: String?    // optional preimage on success
  public var expiresAt: Date?

  public init(
    id: QuoteId = .init(), mint: MintURL, amount: Int64,
    createdAt: Date = .now, status: QuoteStatus = .pending,
    invoice: String? = nil, preimage: String? = nil, expiresAt: Date? = nil
  ) {
    self.id = id; self.mint = mint; self.amount = amount
    self.createdAt = createdAt; self.status = status
    self.invoice = invoice; self.preimage = preimage; self.expiresAt = expiresAt
  }
}
