import Foundation
import CryptoKit
import secp256k1_bindings

public struct BlindedMessage {
    public let amount: Int64
    public let B_: String
    public let secret: Data
    public let r: Data
}

public struct BlindSignature {
    public let amount: Int64
    public let C_: String
}

public enum BlindingError: Error {
    case missingKey, invalidSignature
}

public struct Blinder {
    private let keyset: Keyset

    public init(keyset: Keyset) { self.keyset = keyset }

    // MARK: - Local hex helper (pure Swift, no deps)
    private func hexToData(_ hex: String) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            let byteStr = String(chars[i...i+1])
            guard let byte = UInt8(byteStr, radix: 16) else { return nil }
            data.append(byte)
            i += 2
        }
        return data
    }
}
