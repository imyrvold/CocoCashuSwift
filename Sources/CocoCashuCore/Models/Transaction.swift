import Foundation

public enum TransactionType: String, Codable, Sendable {
    case mint   // Incoming (Lightning -> Cashu)
    case melt   // Outgoing (Cashu -> Lightning)
}

public struct CashuTransaction: Codable, Sendable, Identifiable {
    public let id: UUID
    public let type: TransactionType
    public let amount: Int64
    public let fee: Int64
    public let memo: String?
    public let timestamp: Date
    public var status: TransactionStatus

    public enum TransactionStatus: String, Codable, Sendable {
        case pending, success, failed
    }

    public init(type: TransactionType, amount: Int64, fee: Int64 = 0, memo: String? = nil, status: TransactionStatus = .pending) {
        self.id = UUID()
        self.type = type
        self.amount = amount
        self.fee = fee
        self.memo = memo
        self.timestamp = Date()
        self.status = status
    }
}
