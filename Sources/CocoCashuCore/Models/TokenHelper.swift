import Foundation

/// NUT-00 V3 token structure. Proofs carry ONLY the four spec fields
/// (`id`, `amount`, `secret`, `C`) — the secret as its UTF-8 STRING, not
/// base64-of-Data. The previous serializer embedded the full internal `Proof`
/// (UUID, mint, state, createdAt, base64 secret), which (a) no other Cashu
/// wallet could redeem — while the sender had already marked the proofs spent —
/// and (b) fingerprinted the sender to every recipient via timestamps/UUIDs.
public struct TokenV3: Codable {
    public struct TokenProof: Codable {
        public let id: String
        public let amount: Int64
        public let secret: String
        public let C: String
    }
    public struct TokenEntry: Codable {
        public let mint: String
        public let proofs: [TokenProof]
    }
    public let token: [TokenEntry]
    public let unit: String?
    public let memo: String?
}

/// Which on-the-wire token format to emit. V3 (`cashuA`, base64 JSON) is the
/// most broadly compatible; V4 (`cashuB`, CBOR) is compact — better for NFC
/// cards (limited capacity) and smaller QR codes. All modern wallets read both.
public enum TokenVersion: Sendable {
    case v3
    case v4
}

public enum TokenHelper {
    /// Serialize using the requested format. Proofs must belong to one mint.
    public static func serialize(_ proofs: [Proof], mint: MintURL, memo: String? = nil, version: TokenVersion) throws -> String {
        switch version {
        case .v3: return try serialize(proofs, mint: mint, memo: memo)
        case .v4: return try TokenV4Helper.serialize(proofs, mint: mint, memo: memo)
        }
    }

    public static func serialize(_ proofs: [Proof], mint: MintURL, memo: String? = nil) throws -> String {
        let tokenProofs: [TokenV3.TokenProof] = try proofs.map { p in
            guard let secretString = String(data: p.secret, encoding: .utf8), !secretString.isEmpty else {
                throw CashuError.protocolError("Proof secret is not valid UTF-8 — refusing to serialize a token other wallets cannot redeem")
            }
            return TokenV3.TokenProof(id: p.keysetId, amount: p.amount, secret: secretString, C: p.C)
        }
        let entry = TokenV3.TokenEntry(mint: mint.absoluteString, proofs: tokenProofs)
        let tokenObj = TokenV3(token: [entry], unit: "sat", memo: memo)

        let jsonData = try JSONEncoder().encode(tokenObj)
        let base64 = jsonData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return "cashuA" + base64
    }

    public static func deserialize(_ tokenString: String) throws -> TokenV3 {
        guard tokenString.hasPrefix("cashuA") else {
            throw CashuError.invalidToken
        }

        let safeString = String(tokenString.dropFirst(6))
        var base64 = safeString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad
        while base64.count % 4 != 0 { base64.append("=") }

        guard let data = Data(base64Encoded: base64) else {
            throw CashuError.invalidToken
        }

        return try JSONDecoder().decode(TokenV3.self, from: data)
    }
}
