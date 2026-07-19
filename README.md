# CocoCashuSwift 🥥

A modular Swift SDK for building [Cashu](https://cashu.space) ecash wallets.
The library owns the money: protocol, BDHKE cryptography via libsecp256k1,
DLEQ verification, deterministic (seed-restorable) secrets, durable proof
storage, and multi-mint orchestration — so an app only has to render UI and
provide platform services.

## Modules

- **CocoCashuCore** — protocol, crypto, persistence, orchestration. No UI
  dependencies. Networking (`RealMintAPI`), blinding engine
  (`CocoBlindingEngine`), disk-backed repositories, `WalletStorage`,
  multi-mint API on `CashuManager`.
- **CocoCashuUI** — `ObservableWallet` (an `@Observable` view model),
  `MintCoordinator` (mint/receive flows), and `CashuWalletFactory`.

## Quick start

```swift
import CocoCashuCore
import CocoCashuUI

let wallet = try await CashuWalletFactory.makeWallet(
    defaultMint: URL(string: "https://cashu.cz")!
)
// wallet.totalBalance, wallet.mintBalances, wallet.transactions …
```

One call assembles the whole stack: Keychain-backed seed (created fail-closed
on first launch), disk-backed proof/counter/history/mint stores (atomic,
file-protected, backup-excluded), spec-exact NUT-13 derivation, NUT-12 DLEQ
verification, and launch-time NUT-07 reconciliation of interrupted payments.

**→ See [INTEGRATION.md](INTEGRATION.md) for the full guide**: minting, sending,
receiving (V3+V4 tokens), paying Lightning invoices, seed restore/scanning,
resets, the app-side responsibility checklist, and manual wiring.

## Security properties

- Seed phrases use spec-exact NUT-13 derivation — portable to/from other Cashu
  wallets (Minibits, cashu.me, cdk); validated against the official test vectors.
- Mint responses are verified: NUT-12 DLEQ on blind signatures, NUT-02 keyset-ID
  recomputation, HTTPS enforced (loopback exempt for local development).
- Interrupted payments can't silently lose or double-spend funds: ambiguous
  outcomes park proofs as `.pending` until NUT-07 reconciliation resolves them.
- Derivation counters persist durably and fast-forward after restore scans, so
  deterministic secrets are never reused.

## Supported NUTs

| NUT | Description | Status |
|---|---|---|
| **00** | Cryptography, hash_to_curve, V3 + V4 (CBOR) tokens | ✅ |
| **01** | Mint public keys | ✅ |
| **02** | Keysets, fees, keyset-ID verification | ✅ |
| **03** | Swap (send/receive ecash) | ✅ |
| **04** | Mint tokens (Lightning → ecash) | ✅ |
| **05** | Melt (pay Lightning), quote polling | ✅ |
| **06** | Mint info | ✅ |
| **07** | Proof state check (checkstate) | ✅ |
| **09** | Restore (seed recovery) | ✅ |
| **12** | DLEQ proofs (mint-side verification) | ✅ |
| **13** | Deterministic secrets (v00 BIP32 + v01 HMAC) | ✅ |

## Reference app

[CocoCashuApp](https://github.com/imyrvold/CocoCashuApp) — a complete
iOS/macOS wallet built on this library, including the app-layer hardening the
library can't provide (biometric gate, privacy screen, pasteboard hygiene).
Its `SECURITY_REMEDIATION_PLAN.md` documents the security audit both repos
went through and the live end-to-end verification.

## Development

```bash
swift test   # 26 tests, pinned to official Cashu NUT test vectors
```

# License
MIT License.
