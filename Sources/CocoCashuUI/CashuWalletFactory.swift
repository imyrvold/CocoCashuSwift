import Foundation
import CocoCashuCore

/// Assembles a complete, production-configured wallet. The host app supplies
/// only the two genuinely app-level choices — the default mint and where to
/// store wallet files — and gets back a ready `ObservableWallet`: disk-backed
/// repositories, seed loaded from (or created in) the Keychain, blinding engine,
/// launch-time NUT-07 reconciliation across all mints.
public enum CashuWalletFactory {

    /// Errors here mean the SEED could not be safely established (keychain
    /// unreadable, entropy failure). Callers must fail closed — proceeding
    /// would risk generating a new seed over the real one.
    @MainActor
    public static func makeWallet(
        defaultMint: URL,
        storage: WalletStorage = .standard()
    ) async throws -> ObservableWallet {
        // 1. Disk-backed repositories in the shared wallet directory.
        let proofRepo = FileProofRepository(url: storage.proofsURL)
        let quoteRepo = InMemoryQuoteRepository()
        let mintRepo = FileMintRepository(url: storage.mintsURL)
        // Persistent NUT-13 derivation counter: survives restarts so
        // deterministic secrets are never reused and minted proofs stay
        // restorable from the seed.
        let counterRepo = FileCounterRepository(url: storage.countersURL)

        let api = RealMintAPI(baseURL: defaultMint)

        // 2. Seed: retrieveFromKeychain returns nil ONLY on a positive "no item
        // exists"; any other keychain failure throws through to the caller —
        // generating a new seed on a transient keychain error would overwrite
        // and permanently destroy the real one.
        let seedData: Data
        if let phrase = try SeedManager.shared.retrieveFromKeychain() {
            seedData = try SeedManager.shared.seed(from: phrase)
        } else {
            let newPhrase = try SeedManager.shared.generateNewMnemonic()
            try SeedManager.shared.saveToKeychain(phrase: newPhrase)
            seedData = try SeedManager.shared.seed(from: newPhrase)
        }

        // 3. Blinding engine bound to the seed and the persistent counter.
        let engine = CocoBlindingEngine(seed: seedData, counterRepo: counterRepo) { mintURL in
            try await RealMintAPI(baseURL: mintURL).fetchKeyset()
        }

        // 4. Manager + observable wallet.
        let manager = CashuManager(
            proofRepo: proofRepo,
            mintRepo: mintRepo,
            quoteRepo: quoteRepo,
            counterRepo: counterRepo,
            api: api,
            blinding: engine,
            historyURL: storage.historyURL
        )
        let wallet = ObservableWallet(manager: manager)
        await wallet.refreshAll()

        // 5. Register the default mint, then reconcile any proofs left
        // `.pending` by a prior ambiguous failure or app kill (NUT-07) at every
        // mint that holds them. Best-effort: unreachable mints leave their
        // proofs pending for a later pass.
        await manager.registerMint(defaultMint)
        await manager.reconcileAllPending()
        await wallet.refreshAll()

        return wallet
    }
}
