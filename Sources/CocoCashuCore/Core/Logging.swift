import Foundation

/// Debug-only logging for the wallet. Compiles to a no-op in release builds so
/// wallet activity (amounts, quote IDs, mint error bodies) never reaches the
/// system log of a shipping app, where any paired computer can capture it.
/// Callers must still never pass secrets, seeds, proof secrets, or full tokens.
@inline(__always)
public func cocoLog(_ items: Any...) {
    #if DEBUG
    print(items.map { String(describing: $0) }.joined(separator: " "))
    #endif
}
