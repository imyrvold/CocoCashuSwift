import Foundation

public actor HistoryService {
    private var transactions: [CashuTransaction] = []
    private let events: EventBus
    
    // Simple file persistence for the demo
    private let fileURL: URL

    public init(events: EventBus) {
        self.events = events
        
        // 1. Determine the URL logic first
        let targetURL: URL
        if let appSupport = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            let dir = appSupport.appendingPathComponent("CocoCashuWallet")
            // It is safe to try creating the directory here
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            targetURL = dir.appendingPathComponent("history.json")
        } else {
            // Fallback
            targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("history.json")
        }
        
        // 2. Assign to self.fileURL exactly once
        self.fileURL = targetURL
        
        Task { await load() }
    }
    
    public func add(_ tx: CashuTransaction) {
        transactions.insert(tx, at: 0) // Newest first
        save()
        events.emit(.historyUpdated)
    }
    
    public func fetchAll() -> [CashuTransaction] {
        return transactions
    }

    private func save() {
        if let data = try? JSONEncoder().encode(transactions) {
            try? data.write(to: fileURL)
        }
    }
    
    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([CashuTransaction].self, from: data) {
            self.transactions = loaded.sorted(by: { $0.timestamp > $1.timestamp })
        }
    }
}
