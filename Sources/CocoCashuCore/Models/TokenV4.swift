import Foundation

// CBOR codec lives in CBOR.swift (shared with NUT-18 payment requests).

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
