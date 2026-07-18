import Foundation
import CryptoKit
import secp256k1_bindings

// Minimal secp256k1 helpers built directly on the C bindings.
// These cover: parsing/serializing pubkeys, scalar->pubkey (h*G),
// r*P, add/sub, and RNG.

enum ECError: Error { case context, parsePubKey, serializePubKey, invalidScalar, combineFailed }

@inline(__always) private func withContext<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
  guard let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_SIGN | SECP256K1_CONTEXT_VERIFY)) else {
    throw ECError.context
  }
  defer { secp256k1_context_destroy(ctx) }
  return try body(ctx)
}

@inline(__always) func rng(_ count: Int) -> Data {
  var bytes = [UInt8](repeating: 0, count: count)
  _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
  return Data(bytes)
}

@inline(__always) func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

// Parse compressed pubkey (33 bytes)
func ec_parse_pubkey(_ data: Data) throws -> secp256k1_pubkey {
  return try withContext { ctx in
    var pk = secp256k1_pubkey()
    var bytes = [UInt8](data)
    guard secp256k1_ec_pubkey_parse(ctx, &pk, &bytes, data.count) == 1 else { throw ECError.parsePubKey }
    return pk
  }
}

// Serialize pubkey (compressed)
func ec_serialize_pubkey(_ pk: inout secp256k1_pubkey) throws -> Data {
  return try withContext { ctx in
    var out = [UInt8](repeating: 0, count: 33)
    var outlen: Int = 33
    guard secp256k1_ec_pubkey_serialize(ctx, &out, &outlen, &pk, UInt32(SECP256K1_EC_COMPRESSED)) == 1 else {
      throw ECError.serializePubKey
    }
    return Data(out[0..<outlen])
  }
}

// Serialize pubkey (uncompressed, 65 bytes with 0x04 prefix).
// NUT-12's hash_e concatenates the UNCOMPRESSED hex of each point, so DLEQ
// verification must use this encoding — not the compressed one above.
func ec_serialize_pubkey_uncompressed(_ pk: inout secp256k1_pubkey) throws -> Data {
  return try withContext { ctx in
    var out = [UInt8](repeating: 0, count: 65)
    var outlen: Int = 65
    guard secp256k1_ec_pubkey_serialize(ctx, &out, &outlen, &pk, UInt32(SECP256K1_EC_UNCOMPRESSED)) == 1 else {
      throw ECError.serializePubKey
    }
    return Data(out[0..<outlen])
  }
}

// Create pubkey from a 32-byte scalar: pk = s*G
// The scalar MUST be a valid secp256k1 secret key. Callers pass NUT-13-derived
// blinding factors, which are already reduced into range — so an invalid scalar
// here signals a real bug, and we throw rather than silently substituting
// sha256(scalar) (which would mask the bug and desync from the mint's math).
func ec_pubkey_from_scalar(_ scalar32: Data) throws -> secp256k1_pubkey {
  return try withContext { ctx in
    var sk = [UInt8](scalar32)
    var pk = secp256k1_pubkey()
    guard secp256k1_ec_seckey_verify(ctx, &sk) == 1 else { throw ECError.invalidScalar }
    guard secp256k1_ec_pubkey_create(ctx, &pk, &sk) == 1 else { throw ECError.invalidScalar }
    return pk
  }
}

// Compute r*P. As above, `scalar32` must be a valid scalar; throw on invalid
// input instead of substituting a hash.
func ec_tweak_mul_pubkey(_ P: inout secp256k1_pubkey, _ scalar32: Data) throws -> secp256k1_pubkey {
  return try withContext { ctx in
    var pk = P // copy
    var tweak = [UInt8](scalar32)
    guard secp256k1_ec_seckey_verify(ctx, &tweak) == 1 else { throw ECError.invalidScalar }
    guard secp256k1_ec_pubkey_tweak_mul(ctx, &pk, &tweak) == 1 else { throw ECError.invalidScalar }
    return pk
  }
}

// Combine two pubkeys: A + B
func ec_combine(_ A: inout secp256k1_pubkey, _ B: inout secp256k1_pubkey) throws -> secp256k1_pubkey {
  return try withContext { ctx in
    var out = secp256k1_pubkey()
    // Build an array of pointers as required by secp256k1_ec_pubkey_combine
    return try withUnsafePointer(to: &A) { pA in
      try withUnsafePointer(to: &B) { pB in
        let ins: [UnsafePointer<secp256k1_pubkey>?] = [pA, pB]
        return try ins.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { throw ECError.combineFailed }
            guard secp256k1_ec_pubkey_combine(ctx, &out, base, buf.count) == 1 else {
              throw ECError.combineFailed
            }
          return out
        }
      }
    }
  }
}

// Scalar addition mod n: (key + tweak) mod n, as required by BIP32 CKDpriv.
// Throws when the tweak is out of range or the result is 0 — per BIP32 those
// (astronomically unlikely) cases must be handled by the caller, never masked.
func ec_seckey_tweak_add(_ key32: Data, _ tweak32: Data) throws -> Data {
  return try withContext { ctx in
    var sk = [UInt8](key32)
    var tweak = [UInt8](tweak32)
    guard sk.count == 32, tweak.count == 32 else { throw ECError.invalidScalar }
    guard secp256k1_ec_seckey_tweak_add(ctx, &sk, &tweak) == 1 else {
      throw ECError.invalidScalar
    }
    return Data(sk)
  }
}

// Validity check for a 32-byte scalar as a secp256k1 private key (in [1, n-1]).
func ec_seckey_verify(_ key32: Data) -> Bool {
  guard key32.count == 32 else { return false }
  return (try? withContext { ctx in
    var sk = [UInt8](key32)
    return secp256k1_ec_seckey_verify(ctx, &sk) == 1
  }) ?? false
}

// Negate: -P
func ec_negate(_ P: inout secp256k1_pubkey) throws -> secp256k1_pubkey {
  return try withContext { ctx in
    var pk = P
    guard secp256k1_ec_pubkey_negate(ctx, &pk) == 1 else { throw ECError.combineFailed }
    return pk
  }
}
