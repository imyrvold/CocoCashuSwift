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

//    public func unblind(signatures: [BlindSignature],
//                        messages: [BlindedMessage]) throws -> [Proof] {
//        var out: [Proof] = []
//        for (sig, msg) in zip(signatures, messages) {
//            guard sig.amount == msg.amount else { throw BlindingError.invalidSignature }
//            guard let pubKeyHex = keyset.keys[msg.amount],
//                  let pubKeyData = hexToData(pubKeyHex) else {
//                throw BlindingError.missingKey
//            }
//            var P = try ec_parse_pubkey(pubKeyData)
//
//            // Decode C_ (blind signature) as a curve point (compressed 33 bytes)
//            guard let Cdata = hexToData(sig.C_), Cdata.count == 33 else { throw BlindingError.invalidSignature }
//            var C_blinded = try ec_parse_pubkey(Cdata)
//
//            // r*P
//            var rP = try ec_tweak_mul_pubkey(&P, msg.r)
//
//            // Unblind: C = C_ - r*P  =>  C = C_ + ( - (r*P) )
//            var neg_rP = try ec_negate(&rP)
//            var C_unblinded = try ec_combine(&C_blinded, &neg_rP)
//
//            // If you later extend Proof to store the signature bytes, serialize here:
//            // let C_bytes = try ec_serialize_pubkey(&C_unblinded)
//
//            out.append(Proof(amount: msg.amount,
//                             mint: URL(string: keyset.id)!,
//                             secret: msg.secret))
//        }
//        return out
//    }
    
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
