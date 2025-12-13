import Foundation

public struct TokenV3: Codable {
    public struct TokenEntry: Codable {
        public let mint: String
        public let proofs: [Proof]
    }
    public let token: [TokenEntry]
    public let memo: String?
}

public enum TokenHelper {
    public static func serialize(_ proofs: [Proof], mint: MintURL, memo: String? = nil) throws -> String {
        let entry = TokenV3.TokenEntry(mint: mint.absoluteString, proofs: proofs)
        let tokenObj = TokenV3(token: [entry], memo: memo)
        
        let jsonData = try JSONEncoder().encode(tokenObj)
        let base64 = jsonData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        return "cashuA" + base64
    }

    public static func deserialize(_ tokenString: String) throws -> TokenV3 {
        guard tokenString.hasPrefix("cashuA") else {
            throw NSError(domain: "TokenHelper", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid token prefix"])
        }
        
        let safeString = String(tokenString.dropFirst(6))
        var base64 = safeString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Pad
        while base64.count % 4 != 0 { base64.append("=") }
        
        guard let data = Data(base64Encoded: base64) else {
            throw NSError(domain: "TokenHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid base64"])
        }
        
        return try JSONDecoder().decode(TokenV3.self, from: data)
    }
}
