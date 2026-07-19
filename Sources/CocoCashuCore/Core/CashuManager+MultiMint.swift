import Foundation

/// Result of scanning one mint during a multi-mint restore.
public struct MintScanOutcome: Sendable {
    public let mint: URL
    /// Number of proofs restored, or nil when the scan failed.
    public let restored: Int?
    public let errorDescription: String?
}

/// Pure multi-mint helpers: keep the decision logic out of actors/views so it
/// is directly unit-testable.
public enum MintSelection {
    /// Normalized identity for a mint URL (trailing-slash and case insensitive)
    /// so `https://mint.example` and `https://mint.example/` count as one mint.
    public static func key(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    /// Deduplicate a list of mint URLs, preserving first-seen order.
    public static func dedupe(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert(key($0)).inserted }
    }

    /// Pick the mint to spend `amount` from: the largest balance that covers it
    /// (largest-first keeps small balances intact for small sends). Returns nil
    /// when no single mint covers the amount — a Cashu token/melt spends proofs
    /// from ONE mint, so a sufficient TOTAL across mints is not enough.
    public static func pick(covering amount: Int64, from balances: [(mint: URL, balance: Int64)]) -> URL? {
        balances
            .sorted { $0.balance > $1.balance }
            .first { $0.balance >= amount }?
            .mint
    }
}

public extension CashuManager {
    /// Remember a mint the wallet has interacted with, so multi-mint operations
    /// (scan-all, reconcile-all) can find it later even when no proofs are
    /// currently stored there.
    func registerMint(_ url: URL) async {
        try? await mintRepo.upsert(Mint(base: url))
    }

    /// Every mint worth operating on: the registry plus any mint that stored
    /// proofs reference (covers wallets predating the registry), deduplicated.
    func knownMints() async -> [URL] {
        var urls: [URL] = []
        if let registered = try? await mintRepo.fetchAll() {
            urls.append(contentsOf: registered.map(\.base))
        }
        let unspent = (try? await proofService.getUnspent(mint: nil)) ?? []
        let pending = (try? await proofService.pendingProofs(mint: nil)) ?? []
        let reserved = (try? await proofService.reservedProofs(mint: nil)) ?? []
        urls.append(contentsOf: (unspent + pending + reserved).map(\.mint))
        return MintSelection.dedupe(urls)
    }

    /// Unspent balance per mint, largest first, zero balances omitted.
    func balances() async -> [(mint: URL, balance: Int64)] {
        let unspent = (try? await proofService.getUnspent(mint: nil)) ?? []
        var byKey: [String: (mint: URL, balance: Int64)] = [:]
        for proof in unspent {
            let key = MintSelection.key(proof.mint)
            let current = byKey[key]?.balance ?? 0
            byKey[key] = (byKey[key]?.mint ?? proof.mint, current + proof.amount)
        }
        return byKey.values.sorted { $0.balance > $1.balance }
    }

    /// The mint to spend `amount` from. Throws a descriptive error when no
    /// single mint covers it (tokens/melts spend proofs from one mint only).
    func selectMint(covering amount: Int64) async throws -> URL {
        let current = await balances()
        guard let mint = MintSelection.pick(covering: amount, from: current) else {
            throw CashuError.insufficientFunds
        }
        return mint
    }

    /// Scan every known mint (plus any extras, e.g. a user-entered URL on a
    /// fresh restore) for funds derivable from the seed. Per-mint isolation: one
    /// unreachable mint doesn't abort the rest. Mints where funds were found are
    /// registered so future operations know them.
    func scanAllMints(extra: [URL] = []) async -> [MintScanOutcome] {
        let targets = MintSelection.dedupe(await knownMints() + extra)
        let restorer = WalletRestorationService(manager: self)

        var outcomes: [MintScanOutcome] = []
        for mint in targets {
            do {
                let count = try await restorer.restoreFunds(mintURL: mint)
                if count > 0 { await registerMint(mint) }
                outcomes.append(MintScanOutcome(mint: mint, restored: count, errorDescription: nil))
            } catch {
                outcomes.append(MintScanOutcome(mint: mint, restored: nil, errorDescription: error.localizedDescription))
            }
        }
        return outcomes
    }

    /// NUT-07 reconciliation for every mint that currently holds `.pending`
    /// proofs — not just the default mint (a pending melt at a secondary mint
    /// must resolve too). Best-effort per mint.
    func reconcileAllPending() async {
        let pending = (try? await proofService.pendingProofs(mint: nil)) ?? []
        for mint in MintSelection.dedupe(pending.map(\.mint)) {
            try? await mintService.reconcilePending(mint: mint)
        }
    }
}
