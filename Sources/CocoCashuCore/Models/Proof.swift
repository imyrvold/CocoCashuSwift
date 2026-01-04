import Foundation

public struct Proof: Codable, Sendable, Identifiable, Hashable {
    public let id: ProofId
    public let amount: Int64
    public var mint: MintURL
    public let secret: Data
    public var C: String
    public var keysetId: String
    public var state: ProofState
    public let createdAt: Date
    public var reservedUntil: Date?

    // 1. Define the Mapping
    enum CodingKeys: String, CodingKey {
        // Map JSON "id" -> Swift 'keysetId' (The Cashu Spec)
        case keysetId = "id"
        
        // Map Swift 'id' -> JSON "internalId" (To avoid collision)
        case id = "internalId"
        
        case amount
        case mint
        case secret
        case C
        case state
        case createdAt
        case reservedUntil
    }

    public init(
        id: ProofId = .init(),
        amount: Int64,
        mint: MintURL,
        secret: Data,
        C: String,
        keysetId: String,
        state: ProofState = .unspent,
        createdAt: Date = .now,
        reservedUntil: Date? = nil
    ) {
        self.id = id
        self.amount = amount
        self.mint = mint
        self.secret = secret
        self.C = C
        self.keysetId = keysetId
        self.state = state
        self.createdAt = createdAt
        self.reservedUntil = reservedUntil
    }
    
    // 2. Custom Decoding (Receive)
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Read JSON "id" -> keysetId
        self.keysetId = try container.decode(String.self, forKey: .keysetId)
        
        // Read JSON "internalId" -> id. If missing (standard token), generate new UUID.
        self.id = try container.decodeIfPresent(ProofId.self, forKey: .id) ?? .init()
        
        self.amount = try container.decode(Int64.self, forKey: .amount)
        self.mint = try container.decode(MintURL.self, forKey: .mint)
        self.secret = try container.decode(Data.self, forKey: .secret)
        self.C = try container.decode(String.self, forKey: .C)
        self.state = try container.decodeIfPresent(ProofState.self, forKey: .state) ?? .unspent
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        self.reservedUntil = try container.decodeIfPresent(Date.self, forKey: .reservedUntil)
    }
    
    // 3. Custom Encoding (Send)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        // Write keysetId -> JSON "id"
        try container.encode(keysetId, forKey: .keysetId)
        
        // Write id -> JSON "internalId"
        try container.encode(id, forKey: .id)
        
        try container.encode(amount, forKey: .amount)
        try container.encode(mint, forKey: .mint)
        try container.encode(secret, forKey: .secret)
        try container.encode(C, forKey: .C)
        try container.encode(state, forKey: .state)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(reservedUntil, forKey: .reservedUntil)
    }
}
