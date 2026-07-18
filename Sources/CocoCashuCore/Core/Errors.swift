import Foundation

public enum CashuError: Error, LocalizedError {
  case mintNotFound
  case insufficientFunds
  case invalidQuote
  case network(String)
  case protocolError(String)
  case cryptoError(String)
  case invalidToken
  /// The mint definitively reported the Lightning payment did NOT happen, so the
  /// melt inputs were not consumed and are safe to return to spendable.
  case meltUnpaid
  /// The melt outcome is unknown (mint reported PENDING, or the request timed out /
  /// failed to decode). Inputs may already be spent; they must be reconciled.
  case meltPending(String)

    public var errorDescription: String? {
        switch self {
        case .mintNotFound: return "Mint not found."
        case .insufficientFunds: return "Insufficient funds."
        case .invalidQuote: return "Invalid quote."
        case .network(let msg): return "Network error: \(msg)"
        case .protocolError(let msg): return "Protocol error: \(msg)"
        case .cryptoError(let msg): return "Crypto error: \(msg)"
        case .invalidToken: return "Invalid token."
        case .meltUnpaid: return "The Lightning payment did not go through."
        case .meltPending(let msg): return "Payment pending, verifying: \(msg)"
        }
    }
}
