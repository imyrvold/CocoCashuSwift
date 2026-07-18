import Foundation
import CryptoKit

/// Standard BIP32 hierarchical deterministic key derivation over secp256k1.
///
/// NUT-13 derives Cashu secrets at `m/129372'/0'/{keyset_id_int}'/{counter}'/0`
/// and blinding factors at `.../1` — note the FINAL step is non-hardened, so
/// both hardened and non-hardened CKDpriv are required, and the child key must
/// be `(I_L + k_parent) mod n` per BIP32. (The previous implementation used
/// `I_L` alone and supported only hardened steps, which made seed phrases
/// non-portable: no other Cashu wallet could recover funds from them.)
public struct HDKey {
    /// 32-byte private key, valid in [1, n-1].
    public let privateKey: Data
    public let chainCode: Data

    // Master Node from Seed (BIP32: HMAC-SHA512 keyed with "Bitcoin seed")
    public init(seed: Data) {
        let hmac = HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: "Bitcoin seed".data(using: .utf8)!))
        let data = Data(hmac)
        self.privateKey = data.prefix(32)
        self.chainCode = data.suffix(32)
    }

    private init(privateKey: Data, chainCode: Data) {
        self.privateKey = privateKey
        self.chainCode = chainCode
    }

    /// BIP32 CKDpriv. Supports hardened (index ≥ 0x80000000) and non-hardened
    /// derivation. Returns nil for the (probability ≈ 2⁻¹²⁷) invalid-scalar cases
    /// BIP32 says to skip, and for internal EC failures.
    public func derive(index: UInt32) -> HDKey? {
        var data = Data()

        if index >= 0x80000000 {
            // Hardened: 0x00 || ser256(k_par) || ser32(index)
            data.append(0)
            data.append(privateKey)
        } else {
            // Non-hardened: serP(point(k_par)) || ser32(index)
            guard var pub = try? ec_pubkey_from_scalar(privateKey),
                  let serialized = try? ec_serialize_pubkey(&pub) else { return nil }
            data.append(serialized)
        }

        data.append(withUnsafeBytes(of: index.bigEndian) { Data($0) })

        let hmac = HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: chainCode))
        let output = Data(hmac)
        let IL = output.prefix(32)

        // BIP32: I_L must be a valid scalar and the sum must be non-zero;
        // otherwise the child is invalid (skip). ec_seckey_tweak_add enforces both.
        guard ec_seckey_verify(IL),
              let childKey = try? ec_seckey_tweak_add(privateKey, IL) else { return nil }

        return HDKey(privateKey: childKey, chainCode: output.suffix(32))
    }

    /// Derive along a path of raw indices (add 0x80000000 for hardened steps).
    public func derive(path: [UInt32]) -> HDKey? {
        var current = self
        for index in path {
            guard let next = current.derive(index: index) else { return nil }
            current = next
        }
        return current
    }
}
