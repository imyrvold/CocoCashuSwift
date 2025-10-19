import Foundation

public protocol CashuPlugin: Sendable {
  func onManagerReady(manager: CashuManager) async
  func onEvent(_ event: WalletEvent) async
}

extension CashuPlugin {
  public func onManagerReady(manager: CashuManager) async {}
  public func onEvent(_ event: WalletEvent) async {}
}
