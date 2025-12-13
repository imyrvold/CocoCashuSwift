import Foundation

public enum CashuError: Error, LocalizedError {
  case mintNotFound
  case insufficientFunds
  case invalidQuote
  case network(String)
  case protocolError(String)
    
    public var errorDescription: String? {
        switch self {
        case .mintNotFound: return "Mint not found."
        case .insufficientFunds: return "Insufficient funds."
        case .invalidQuote: return "Invalid quote."
        case .network(let msg): return "Network error: \(msg)"
        case .protocolError(let msg): return "Protocol error: \(msg)"
        }
    }
}
