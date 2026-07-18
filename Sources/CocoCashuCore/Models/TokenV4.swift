import Foundation

// MARK: - Minimal CBOR decoder (NUT-00 V4 "cashuB" tokens)
//
// V4 tokens are CBOR, not JSON — feeding them to JSONDecoder fails with
// "data couldn't be read", which broke receiving from modern wallets
// (Minibits, cashu.me default to cashuB). This is a deliberately small,
// hardened decoder for the subset CBOR the token format uses: definite-length
// unsigned ints, byte strings, text strings, arrays, and text-keyed maps.
// Input is untrusted (pasted/scanned), so every read is bounds-checked, nesting
// depth is capped, and anything outside the subset is rejected rather than
// guessed at.

enum CBORValue {
    case unsigned(UInt64)
    case bytes(Data)
    case text(String)
    case array([CBORValue])
    case map([String: CBORValue])
    case bool(Bool)
    case null
}

struct CBORDecodeError: Error { let reason: String }

struct CBORDecoder {
    private let data: Data
    private var index: Data.Index
    private static let maxDepth = 16

    init(data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    static func decode(_ data: Data) throws -> CBORValue {
        var decoder = CBORDecoder(data: data)
        let value = try decoder.decodeItem(depth: 0)
        guard decoder.index == data.endIndex else {
            throw CBORDecodeError(reason: "Trailing bytes after CBOR value")
        }
        return value
    }

    private mutating func readByte() throws -> UInt8 {
        guard index < data.endIndex else { throw CBORDecodeError(reason: "Unexpected end of data") }
        defer { index = data.index(after: index) }
        return data[index]
    }

    private mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, data.distance(from: index, to: data.endIndex) >= count else {
            throw CBORDecodeError(reason: "Unexpected end of data")
        }
        let end = data.index(index, offsetBy: count)
        defer { index = end }
        return Data(data[index..<end])
    }

    /// Read the "argument" for a major type: the length or the integer value.
    private mutating func readArgument(_ additional: UInt8) throws -> UInt64 {
        switch additional {
        case 0...23: return UInt64(additional)
        case 24: return UInt64(try readByte())
        case 25:
            let b = try readBytes(2)
            return b.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        case 26:
            let b = try readBytes(4)
            return b.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        case 27:
            let b = try readBytes(8)
            return b.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        default:
            // 28-30 reserved, 31 = indefinite length (not used by token emitters)
            throw CBORDecodeError(reason: "Unsupported CBOR length encoding \(additional)")
        }
    }

    private mutating func decodeItem(depth: Int) throws -> CBORValue {
        guard depth < Self.maxDepth else { throw CBORDecodeError(reason: "CBOR nesting too deep") }
        let initial = try readByte()
        let majorType = initial >> 5
        let additional = initial & 0x1F

        switch majorType {
        case 0: // unsigned integer
            return .unsigned(try readArgument(additional))
        case 2: // byte string
            let length = try readArgument(additional)
            guard length <= UInt64(Int.max) else { throw CBORDecodeError(reason: "Byte string too long") }
            return .bytes(try readBytes(Int(length)))
        case 3: // text string
            let length = try readArgument(additional)
            guard length <= UInt64(Int.max) else { throw CBORDecodeError(reason: "Text string too long") }
            let raw = try readBytes(Int(length))
            guard let text = String(data: raw, encoding: .utf8) else {
                throw CBORDecodeError(reason: "Invalid UTF-8 in text string")
            }
            return .text(text)
        case 4: // array
            let count = try readArgument(additional)
            guard count <= 4096 else { throw CBORDecodeError(reason: "Array too large") }
            var items: [CBORValue] = []
            items.reserveCapacity(Int(count))
            for _ in 0..<count { items.append(try decodeItem(depth: depth + 1)) }
            return .array(items)
        case 5: // map — token maps are keyed by short text strings
            let count = try readArgument(additional)
            guard count <= 64 else { throw CBORDecodeError(reason: "Map too large") }
            var map: [String: CBORValue] = [:]
            for _ in 0..<count {
                guard case .text(let key) = try decodeItem(depth: depth + 1) else {
                    throw CBORDecodeError(reason: "Non-text map key")
                }
                map[key] = try decodeItem(depth: depth + 1)
            }
            return .map(map)
        case 7: // simple values
            switch additional {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            default: throw CBORDecodeError(reason: "Unsupported CBOR simple value \(additional)")
            }
        default:
            throw CBORDecodeError(reason: "Unsupported CBOR major type \(majorType)")
        }
    }
}

// MARK: - NUT-00 V4 token

/// Decoded V4 (cashuB) token: `{m: mint, u: unit, d?: memo, t: [{i: keyset-id
/// bytes, p: [{a: amount, s: secret, c: C bytes, d?: dleq, w?: witness}]}]}`.
public struct TokenV4: Sendable {
    public struct TokenProof: Sendable {
        public let keysetId: String   // hex of the `i` byte string
        public let amount: Int64
        public let secret: String
        public let C: String          // hex of the `c` byte string
        public let dleq: DLEQProof?
    }
    public let mint: String
    public let unit: String?
    public let memo: String?
    public let proofs: [TokenProof]
}

public enum TokenV4Helper {
    /// Deserialize a `cashuB…` string. Only decoding/shape errors throw
    /// `CashuError.invalidToken`; amount validation is left to the caller so it
    /// can apply the same policy as V3 tokens.
    public static func deserialize(_ tokenString: String) throws -> TokenV4 {
        guard tokenString.hasPrefix("cashuB") else { throw CashuError.invalidToken }

        var base64 = String(tokenString.dropFirst(6))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }

        guard let data = Data(base64Encoded: base64) else { throw CashuError.invalidToken }

        guard case .map(let root) = try? CBORDecoder.decode(data) else {
            throw CashuError.invalidToken
        }
        guard case .text(let mint)? = root["m"], !mint.isEmpty,
              case .array(let entries)? = root["t"] else {
            throw CashuError.invalidToken
        }
        var unit: String? = nil
        if case .text(let u)? = root["u"] { unit = u }
        var memo: String? = nil
        if case .text(let d)? = root["d"] { memo = d }

        var proofs: [TokenV4.TokenProof] = []
        for entry in entries {
            guard case .map(let e) = entry,
                  case .bytes(let keysetIdBytes)? = e["i"],
                  case .array(let proofItems)? = e["p"] else {
                throw CashuError.invalidToken
            }
            let keysetId = keysetIdBytes.hexString
            for item in proofItems {
                guard case .map(let p) = item,
                      case .unsigned(let rawAmount)? = p["a"],
                      rawAmount <= UInt64(Int64.max),
                      case .text(let secret)? = p["s"],
                      case .bytes(let cBytes)? = p["c"] else {
                    throw CashuError.invalidToken
                }
                var dleq: DLEQProof? = nil
                if case .map(let d)? = p["d"],
                   case .bytes(let eBytes)? = d["e"],
                   case .bytes(let sBytes)? = d["s"] {
                    var rHex: String? = nil
                    if case .bytes(let rBytes)? = d["r"] { rHex = rBytes.hexString }
                    dleq = DLEQProof(e: eBytes.hexString, s: sBytes.hexString, r: rHex)
                }
                proofs.append(TokenV4.TokenProof(
                    keysetId: keysetId,
                    amount: Int64(rawAmount),
                    secret: secret,
                    C: cBytes.hexString,
                    dleq: dleq
                ))
            }
        }
        guard !proofs.isEmpty else { throw CashuError.invalidToken }

        return TokenV4(mint: mint, unit: unit, memo: memo, proofs: proofs)
    }
}
