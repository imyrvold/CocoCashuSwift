import Foundation

public actor HistoryService {
    private var transactions: [CashuTransaction] = []
    private let events: EventBus
    
    // Simple file persistence for the demo
    private let fileURL: URL

    /// `fileURL` nil falls back to the standard wallet directory — pass
    /// `WalletStorage.historyURL` so all wallet files share one layout.
    public init(events: EventBus, fileURL: URL? = nil) {
        self.events = events
        self.fileURL = fileURL ?? WalletStorage.standard().historyURL
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
            // Atomic + complete file protection, matching proofs.json: history
            // reveals amounts/timestamps, and a torn write corrupts the file.
            var options: Data.WritingOptions = [.atomic]
            #if os(iOS)
            options.insert(.completeFileProtection)
            #endif
            try? data.write(to: fileURL, options: options)
        }
    }
    
    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode([CashuTransaction].self, from: data) {
            self.transactions = loaded.sorted(by: { $0.timestamp > $1.timestamp })
        }
    }
}
