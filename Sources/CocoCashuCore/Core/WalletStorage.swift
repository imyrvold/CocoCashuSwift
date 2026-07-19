import Foundation

/// Owns the wallet's on-disk layout: one directory containing the proof store,
/// NUT-13 counters, transaction history, and the mint registry. Centralizing it
/// here (instead of each layer computing its own paths) keeps the security
/// properties in one place — the directory is created once and excluded from
/// iCloud/iTunes backups, so bearer proofs and derivation counters can't be
/// exfiltrated via a backup or restored onto another device.
public struct WalletStorage: Sendable {
    public let directory: URL

    public var proofsURL: URL { directory.appendingPathComponent("proofs.json") }
    public var countersURL: URL { directory.appendingPathComponent("counters.json") }
    public var historyURL: URL { directory.appendingPathComponent("history.json") }
    public var mintsURL: URL { directory.appendingPathComponent("mints.json") }

    public init(directory: URL) {
        self.directory = directory
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    /// The standard location: Application Support/CocoCashuWallet (temporary
    /// directory as a last resort when Application Support is unavailable).
    public static func standard() -> WalletStorage {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return WalletStorage(directory: base.appendingPathComponent("CocoCashuWallet", isDirectory: true))
    }

    // MARK: - Resets

    /// Remove stored proofs only. Keeps the seed and the NUT-13 counter, so
    /// future derivations continue forward and never reuse blinded outputs.
    public func clearBalance() {
        try? FileManager.default.removeItem(at: proofsURL)
    }

    /// Remove every wallet file, for a full reset to a brand-new seed (the
    /// caller deletes the seed from the Keychain). History must go too —
    /// amounts/timestamps surviving a "full" reset would leak the old wallet's
    /// activity onto the supposedly clean one.
    public func resetForNewSeed() {
        try? FileManager.default.removeItem(at: proofsURL)
        try? FileManager.default.removeItem(at: countersURL)
        try? FileManager.default.removeItem(at: historyURL)
        try? FileManager.default.removeItem(at: mintsURL)
    }

    /// Remove state belonging to the OLD seed after a different seed was
    /// imported: proofs, counters, and history. The mint registry is KEPT —
    /// mints aren't seed-specific, and the imported seed's funds are most
    /// likely at those same mints, so the post-import scan finds them without
    /// the user re-entering mint URLs.
    public func resetForImportedSeed() {
        try? FileManager.default.removeItem(at: proofsURL)
        try? FileManager.default.removeItem(at: countersURL)
        try? FileManager.default.removeItem(at: historyURL)
    }
}
