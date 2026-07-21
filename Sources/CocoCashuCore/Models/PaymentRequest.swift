import Foundation

/// NUT-18 payment request: a receiver-published "pay me" artifact
/// (`creqA` + base64url(CBOR)). The payer decodes it to learn how much, in
/// which unit, and from which mint(s) to pay, then produces a matching token.
///
/// CBOR field keys (all optional per spec): `i` id, `a` amount, `u` unit,
/// `s` single-use, `m` allowed mints, `d` description, `t` transports,
/// `nut10` locking condition. Transports we don't act on (nostr/post) are
/// preserved opaquely so a decode→encode round-trip is faithful.
public struct PaymentRequest: Sendable, Equatable {
    public struct Transport: Sendable, Equatable {
        public let type: String          // "nostr" | "post" | …
        public let target: String
        public let tags: [[String]]
        public init(type: String, target: String, tags: [[String]] = []) {
            self.type = type; self.target = target; self.tags = tags
        }
    }

    public var id: String?
    public var amount: Int64?
    public var unit: String?
    public var singleUse: Bool?
    public var mints: [String]
    public var description: String?
    public var transports: [Transport]

    public init(id: String? = nil, amount: Int64? = nil, unit: String? = nil,
                singleUse: Bool? = nil, mints: [String] = [], description: String? = nil,
                transports: [Transport] = []) {
        self.id = id; self.amount = amount; self.unit = unit
        self.singleUse = singleUse; self.mints = mints
        self.description = description; self.transports = transports
    }

    // MARK: Decoding

    /// Decode a `creqA…` string. Throws `CashuError.invalidToken` on anything
    /// that isn't a well-formed NUT-18 request.
    public static func decode(_ raw: String) throws -> PaymentRequest {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("creqA") else { throw CashuError.invalidToken }

        var b64 = String(trimmed.dropFirst(5))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64) else { throw CashuError.invalidToken }

        guard case .map(let root) = try? CBORDecoder.decode(data) else {
            throw CashuError.invalidToken
        }

        var request = PaymentRequest()
        if case .text(let id)? = root["i"] { request.id = id }
        if case .unsigned(let a)? = root["a"], a <= UInt64(Int64.max) { request.amount = Int64(a) }
        if case .text(let u)? = root["u"] { request.unit = u }
        if case .bool(let s)? = root["s"] { request.singleUse = s }
        if case .text(let d)? = root["d"] { request.description = d }
        if case .array(let m)? = root["m"] {
            request.mints = m.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
        }
        if case .array(let ts)? = root["t"] {
            request.transports = ts.compactMap { entry in
                guard case .map(let t) = entry,
                      case .text(let type)? = t["t"],
                      case .text(let target)? = t["a"] else { return nil }
                var tags: [[String]] = []
                if case .array(let gs)? = t["g"] {
                    tags = gs.compactMap { g in
                        if case .array(let inner) = g {
                            return inner.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
                        }
                        return nil
                    }
                }
                return Transport(type: type, target: target, tags: tags)
            }
        }
        return request
    }

    // MARK: Encoding

    /// Encode to a `creqA…` string. Emits fields in the canonical key order
    /// (t, i, a, u, s, m, d), omitting absent optionals, matching the field
    /// order other Cashu implementations produce.
    public func encode() throws -> String {
        var enc = CBOREncoder()

        // Count present keys for the map header.
        var keyCount = mints.isEmpty ? 0 : 1
        if !transports.isEmpty { keyCount += 1 }
        if id != nil { keyCount += 1 }
        if amount != nil { keyCount += 1 }
        if unit != nil { keyCount += 1 }
        if singleUse != nil { keyCount += 1 }
        if description != nil { keyCount += 1 }
        enc.appendMapHeader(count: keyCount)

        if !transports.isEmpty {
            enc.appendText("t")
            enc.appendArrayHeader(count: transports.count)
            for transport in transports {
                let hasTags = !transport.tags.isEmpty
                enc.appendMapHeader(count: hasTags ? 3 : 2)
                enc.appendText("t"); enc.appendText(transport.type)
                enc.appendText("a"); enc.appendText(transport.target)
                if hasTags {
                    enc.appendText("g")
                    enc.appendArrayHeader(count: transport.tags.count)
                    for tag in transport.tags {
                        enc.appendArrayHeader(count: tag.count)
                        for element in tag { enc.appendText(element) }
                    }
                }
            }
        }
        if let id { enc.appendText("i"); enc.appendText(id) }
        if let amount {
            guard amount >= 0 else { throw CashuError.protocolError("Payment request amount must be non-negative") }
            enc.appendText("a"); enc.appendUnsigned(UInt64(amount))
        }
        if let unit { enc.appendText("u"); enc.appendText(unit) }
        if let singleUse { enc.appendText("s"); enc.appendBool(singleUse) }
        if !mints.isEmpty {
            enc.appendText("m")
            enc.appendArrayHeader(count: mints.count)
            for mint in mints { enc.appendText(mint) }
        }
        if let description { enc.appendText("d"); enc.appendText(description) }

        let b64 = enc.data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "creqA" + b64
    }
}
