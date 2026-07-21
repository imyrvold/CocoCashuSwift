import Foundation

// Minimal CBOR codec shared by the CBOR-encoded Cashu formats: NUT-00 V4
// ("cashuB") tokens and NUT-18 ("creqA") payment requests.
//
// A deliberately small, hardened subset — definite-length unsigned ints, byte
// strings, text strings, arrays, text-keyed maps, and the three simple values
// (false/true/null). Input is untrusted (pasted/scanned), so every read is
// bounds-checked, nesting depth is capped, and anything outside the subset is
// rejected rather than guessed at. The encoder writes maps from an explicit,
// caller-chosen key order so output is deterministic and matches what other
// Cashu implementations emit.

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
        case 5: // map — Cashu maps are keyed by short text strings
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
    mutating func appendBool(_ value: Bool) { data.append((7 << 5) | (value ? 21 : 20)) }
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
