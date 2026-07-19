# Integrating CocoCashuSwift into a new app

This guide shows how to wire a complete Cashu wallet into a new iOS/macOS app.
The reference implementation is [CocoCashuApp](https://github.com/imyrvold/CocoCashuApp) —
when in doubt, read how it calls the library.

## Requirements

- iOS 17+ / macOS 14+ (Swift 6 toolchain)
- The app must be able to use the **Keychain** (the BIP39 seed lives there)
- Mints must be reachable over **HTTPS** (the library refuses `http://` except
  loopback, and default ATS enforces the same on iOS)

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/imyrvold/CocoCashuSwift.git", branch: "main")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "CocoCashuCore", package: "CocoCashuSwift"),
        .product(name: "CocoCashuUI",   package: "CocoCashuSwift"),
    ])
]
```

- **CocoCashuCore** — protocol, crypto, persistence, orchestration. No UI.
- **CocoCashuUI** — `ObservableWallet` (an `@Observable` view model),
  `MintCoordinator` (mint/receive flows), and the wallet factory.

## Quick start (recommended)

One call builds a production-configured wallet:

```swift
import CocoCashuCore
import CocoCashuUI

@MainActor
enum WalletBootstrap {
    static let defaultMint = URL(string: "https://cashu.cz")!
    static let storage = WalletStorage.standard()

    static func makeWallet() async -> ObservableWallet {
        do {
            return try await CashuWalletFactory.makeWallet(
                defaultMint: defaultMint,
                storage: storage
            )
        } catch {
            // A throw means the SEED could not be safely established (keychain
            // unreadable, entropy failure). FAIL CLOSED — do not retry into a
            // fresh seed: that would overwrite and destroy the real one.
            fatalError("Wallet seed could not be initialized: \(error)")
        }
    }
}
```

```swift
@main
struct YourApp: App {
    @State private var wallet: ObservableWallet?

    var body: some Scene {
        WindowGroup {
            Group {
                if let wallet { ContentView(wallet: wallet) }
                else { ProgressView("Loading wallet…") }
            }
            .task { wallet = await WalletBootstrap.makeWallet() }
        }
    }
}
```

What the factory gives you:

- **Seed** loaded from the Keychain, or generated (checked CSPRNG entropy) and
  stored `WhenUnlockedThisDeviceOnly` on first launch. Keychain read errors
  throw rather than silently minting a new seed over the real one.
- **Disk-backed stores** for proofs, NUT-13 counters, history, and the mint
  registry — atomic writes, complete file protection (iOS), one directory
  excluded from backups (`WalletStorage`).
- **Blinding engine** with spec-exact NUT-13 derivation (seed phrases are
  portable to/from other Cashu wallets) and NUT-12 DLEQ verification of mint
  signatures.
- **Launch reconciliation**: proofs left `.pending` by an interrupted payment
  are resolved against every mint via NUT-07 on startup.

## The core flows

All examples below assume `let wallet: ObservableWallet` and
`let manager = wallet.manager`.

### Balances (display state)

```swift
wallet.totalBalance                    // Int64, unspent sats across all mints
wallet.mintBalances                    // [(host, balance, url)], largest first
wallet.proofsByMint                    // raw per-mint proofs, auto-updating
wallet.transactions                    // [CashuTransaction] history, newest first
```

`ObservableWallet` is `@Observable`; views using these re-render automatically.

### Mint (Lightning → ecash)

```swift
let coordinator = MintCoordinator(
    manager: manager,
    api: RealMintAPI(baseURL: mint),
    blinding: manager.blinding
)
let (invoice, quoteId) = try await coordinator.topUp(mint: mint, amount: 100)
// Show `invoice` to the user (QR / copy), then:
try await coordinator.pollUntilPaid(mint: mint, invoice: invoice, quoteId: quoteId)
try await coordinator.receiveTokens(mint: mint, invoice: invoice, quoteId: quoteId, amount: 100)
```

`receiveTokens` self-heals "already signed" mint responses via NUT-09 restore.

### Send (create an ecash token)

```swift
// A token spends proofs from ONE mint. Let the library pick one that covers
// the amount (throws when no single mint does, even if the total would):
let mint = try await manager.selectMint(covering: amount)
let token = try await manager.mintService.createToken(amount: amount, from: mint)
// `token` is a NUT-00 V3 "cashuA…" string any Cashu wallet can redeem.
```

The token string is the ONLY handle on that money until the recipient claims
it — don't discard it without user confirmation (unclaimed funds are then only
recoverable by a seed scan).

### Receive (claim a pasted token)

```swift
let coordinator = MintCoordinator(manager: manager,
                                  api: RealMintAPI(baseURL: WalletBootstrap.defaultMint),
                                  blinding: manager.blinding)
try await coordinator.receive(token: pastedString)
```

Accepts V3 (`cashuA`, JSON) and V4 (`cashuB`, CBOR — what Minibits/cashu.me
send) tokens; parses against size/proof-count bounds, enforces HTTPS on the
token's mint, validates the keyset (NUT-02), and swaps at the token's own mint.
The mint is registered automatically for future multi-mint operations.

### Pay a Lightning invoice (melt)

```swift
let mint = try await manager.selectMint(covering: amountSats)
let result = try await manager.mintService.spend(amount: amountSats, from: mint, to: bolt11)
switch result {
case .paid(let feePaid):
    // settled; change already recovered into the wallet
case .pending:
    // NOT a failure: the mint accepted the melt but the Lightning payment is
    // still in flight after ~90s of polling. Funds are parked and will be
    // reconciled automatically (next launch, or call reconcileAllPending()).
}
```

Show the user an amount preview with `BOLT11.amountSats(from: invoice)` (nil
for amountless or fractional-sat invoices). The mint's quote is authoritative —
`spend` aborts if it disagrees with the amount you pass.

Safety behavior you get for free: fee reserve capped at max(10 sats, 2%),
definitive UNPAID releases funds, ambiguous outcomes park funds as `.pending`
(never silently spendable, never lost).

### Restore from seed / scan for funds

```swift
// After the user imports a seed into the Keychain (SeedManager.saveToKeychain):
WalletBootstrap.storage.resetForImportedSeed()   // wipe old seed's state
// … relaunch/rebuild the wallet, then:
let outcomes = try await wallet.scanAllMints(extraMintString: userEnteredMintURL)
for o in outcomes {
    print(o.mint, o.restored ?? "failed: \(o.errorDescription ?? "?")")
}
```

The scan sweeps every known mint (registry + mints holding proofs) plus the
optional extra URL, restores proofs via NUT-09 with per-mint failure isolation,
verifies them unspent via NUT-07, and fast-forwards the NUT-13 counters so the
wallet never re-derives already-signed secrets. On a FRESH install only the
default mint is known — give the user a field to enter other mints they used.

### Seed backup UI

```swift
let phrase: [String]? = try SeedManager.shared.retrieveFromKeychain()
```

Returns nil only when no seed exists; throws on other keychain failures (do not
treat those as "no wallet"). Gate the reveal behind `LocalAuthentication`.

### Resets

```swift
WalletBootstrap.storage.clearBalance()          // proofs only; seed+counters kept
WalletBootstrap.storage.resetForNewSeed()       // all files…
SeedManager.shared.deleteFromKeychain()         // …and the seed
WalletBootstrap.storage.resetForImportedSeed()  // old seed's state; keeps mint registry
```

After changing the seed, terminate/rebuild the wallet object — the blinding
engine binds the seed at construction.

## App responsibilities (the library can't do these)

The library owns money, protocol, and persistence. These are on you:

- **Privacy screen**: cover the UI when `scenePhase != .active` so balances and
  seed words never land in the app-switcher snapshot; mark sensitive views
  `.privacySensitive()`.
- **Biometric gate** on seed reveal (`LAContext`, `.deviceOwnerAuthentication`).
- **Pasteboard hygiene**: copy the seed with `.localOnly` + short
  `.expirationDate`; copy tokens/invoices with an expiration.
- **QR scanning/generation** (camera permission, `CIQRCodeGenerator`).
- **Confirmation UX**: warn before discarding an unshown token; treat
  `MeltResult.pending` as "processing", never as failure.

CocoCashuApp implements all of these — copy freely.

## Manual wiring (only if the factory doesn't fit)

`CashuWalletFactory` is ~60 lines; replicate it if you need custom pieces.
Non-negotiables if you do:

- Use **`FileCounterRepository`** (or another durable `CounterRepository`).
  `InMemoryCounterRepository` is for tests only: counters resetting to 0 means
  NUT-13 secrets get re-derived and reused — rejected mints or ambiguous funds.
- Use **`FileProofRepository`** (or another durable `ProofRepository`) — proofs
  ARE the money.
- Handle `SeedManager.retrieveFromKeychain()` errors by failing closed.
- Keep every store inside one backup-excluded directory (`WalletStorage` does
  this for you even in manual setups).

## Testing

`swift test` runs the suite (26 tests), which pins the crypto to the official
Cashu test vectors (NUT-00 hash_to_curve & V4 tokens, NUT-12 DLEQ, NUT-13
v00/v01 derivation) plus persistence and multi-mint behavior. Live mints used
during development: `https://cashu.cz` and `https://mint.minibits.cash/Bitcoin`
(also useful: a local nutshell mint at `http://localhost:3338` — loopback HTTP
is allowed for development).
