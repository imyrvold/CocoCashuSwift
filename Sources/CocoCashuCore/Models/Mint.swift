import Foundation

public struct Mint: Codable, Sendable, Identifiable, Hashable {
  public var id: String { base.absoluteString }
  public let base: MintURL
  public let name: String?

  public init(base: MintURL, name: String? = nil) {
    self.base = base; self.name = name
  }
}

