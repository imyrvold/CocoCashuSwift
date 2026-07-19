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

// MARK: - Minimal CBOR encoder (for producing cashuB tokens)
//
// Counterpart to the decoder above, covering the same subset. Maps are encoded
// from ordered key/value pairs so output is deterministic and matches the field
// order other Cashu implementations emit (t, d, m, u / i, p / a, s, c).

struct CBOREncoder {
    private(set) var data = Data()

    private mutating func writeHeader(major: UInt8, argument: UInt64) {
        let majorBits = major << 5
        switch argument {
        case 0...23:
            data.append(majorBits | UInt8(argument))
        case 24...UInt64(UInt8.max):
            data.append(majorBits | 24)
            data.append(UInt8(argument))
        case (UInt64(UInt8.max) + 1)...UInt64(UInt16.max):
            data.append(majorBits | 25)
            withUnsafeBytes(of: UInt16(argument).bigEndian) { data.append(contentsOf: $0) }
        case (UInt64(UInt16.max) + 1)...UInt64(UInt32.max):
            data.append(majorBits | 26)
            withUnsafeBytes(of: UInt32(argument).bigEndian) { data.append(contentsOf: $0) }
        default:
            data.append(majorBits | 27)
            withUnsafeBytes(of: argument.bigEndian) { data.append(contentsOf: $0) }
        }
    }

    mutating func appendUnsigned(_ value: UInt64) { writeHeader(major: 0, argument: value) }
    mutating func appendBytes(_ bytes: Data) {
        writeHeader(major: 2, argument: UInt64(bytes.count))
        data.append(bytes)
    }
    mutating func appendText(_ text: String) {
        let utf8 = Data(text.utf8)
        writeHeader(major: 3, argument: UInt64(utf8.count))
        data.append(utf8)
    }
    mutating func appendArrayHeader(count: Int) { writeHeader(major: 4, argument: UInt64(count)) }
    mutating func appendMapHeader(count: Int) { writeHeader(major: 5, argument: UInt64(count)) }
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
    /// Serialize proofs to a `cashuB…` V4 (CBOR) token. All proofs must belong to
    /// one mint (V4's structure is single-mint). Compact output — smaller QR
    /// codes and a better fit for NFC-card capacity than V3's base64 JSON — with
    /// the secret emitted as its UTF-8 string per NUT-00 (a proof whose secret
    /// isn't UTF-8 is rejected rather than written into an unredeemable token).
    public static func serialize(_ proofs: [Proof], mint: MintURL, unit: String = "sat", memo: String? = nil) throws -> String {
        guard !proofs.isEmpty else { throw CashuError.invalidToken }

        // Group proofs by keyset id → the `t` array's entries.
        var order: [String] = []
        var byKeyset: [String: [Proof]] = [:]
        for p in proofs {
            if byKeyset[p.keysetId] == nil { order.append(p.keysetId) }
            byKeyset[p.keysetId, default: []].append(p)
        }

        var enc = CBOREncoder()
        enc.appendMapHeader(count: memo == nil ? 3 : 4)   // root: t, (d), m, u

        enc.appendText("t")
        enc.appendArrayHeader(count: order.count)
        for keysetId in order {
            guard let idBytes = Data(hex: keysetId) else {
                throw CashuError.protocolError("Keyset ID '\(keysetId)' is not hex; cannot serialize as V4")
            }
            let group = byKeyset[keysetId] ?? []
            enc.appendMapHeader(count: 2)                 // { i, p }
            enc.appendText("i"); enc.appendBytes(idBytes)
            enc.appendText("p")
            enc.appendArrayHeader(count: group.count)
            for p in group {
                guard let secret = String(data: p.secret, encoding: .utf8), !secret.isEmpty else {
                    throw CashuError.protocolError("Proof secret is not valid UTF-8; cannot serialize as V4")
                }
                guard let cBytes = Data(hex: p.C) else {
                    throw CashuError.protocolError("Proof signature is not hex; cannot serialize as V4")
                }
                guard p.amount >= 0 else { throw CashuError.invalidToken }
                enc.appendMapHeader(count: 3)             // { a, s, c }
                enc.appendText("a"); enc.appendUnsigned(UInt64(p.amount))
                enc.appendText("s"); enc.appendText(secret)
                enc.appendText("c"); enc.appendBytes(cBytes)
            }
        }

        if let memo { enc.appendText("d"); enc.appendText(memo) }
        enc.appendText("m"); enc.appendText(mint.absoluteString)
        enc.appendText("u"); enc.appendText(unit)

        let b64 = enc.data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "cashuB" + b64
    }

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
