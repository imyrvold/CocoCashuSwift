public enum CashuError: Error {
  case mintNotFound
  case insufficientFunds
  case invalidQuote
  case network(String)
  case protocolError(String)
}
