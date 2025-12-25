# CocoCashuSwift 🥥Lib

A comprehensive, modular Swift SDK for building [Cashu](https://cashu.space) wallets. This library abstracts away the complexities of NUT protocols, blinding signatures, and proof management, allowing you to focus on building great UI.

## Modules

The library is split into two targets to ensure separation of concerns:

### 1. CocoCashuCore
The engine room. Pure Swift logic with ****no UI dependencies****.
- ****Networking:**** `RealMintAPI` handling NUT-04 (Mint), NUT-05 (Melt), and NUT-06 (Split).
- ****Cryptography:**** BDHKE (Blind Diffie-Hellman Key Exchange) implementation using `ksec` primitives.
- ****Storage:**** Actor-based `ProofRegistry` and `MintRegistry` for thread-safe persistence.
- ****Models:**** Codable structs for `Proof`, `Token`, `BlindedSignature`, etc.

### 2. CocoCashuUI
SwiftUI helpers and state management.
- ****ObservableWallet:**** A complete `@Observable` View Model that manages the wallet lifecycle.
- ****MintCoordinator:**** Encapsulates the complex state machine of the Minting flow (Invoice -> Polling -> Blinding -> Signing).

## Installation

Add this package to your project via Swift Package Manager:

```swift
// Package.swift
dependencies: [
    .package(url: "[https://github.com/yourusername/CocoCashuSwift.git](https://github.com/yourusername/CocoCashuSwift.git)", from: "0.1.0")
]
```

## Usage Example
**Initializing the Manager**
```swift
import CocoCashuCore
import CocoCashuUI

// 1. Setup the Network Layer
let api = RealMintAPI(baseURL: URL(string: "[https://cashu.cz](https://cashu.cz)")!)

// 2. Setup the Blinding Engine
let engine = CocoBlindingEngine { mintURL in
    try await RealMintAPI(baseURL: mintURL).fetchKeyset()
}

// 3. Initialize the Manager
let manager = CashuManager(
    proofRepo: ProofRegistry(),
    mintRepo: MintRegistry(),
    quoteRepo: InMemoryQuoteRepository(),
    counterRepo: InMemoryCounterRepository(),
    api: api,
    blinding: engine
)

// 4. Create the Wallet View Model
let wallet = ObservableWallet(manager: manager)
```

**Minting Tokens**
```swift
let coordinator = MintCoordinator(manager: manager, api: manager.api, blinding: manager.blinding)

// 1. Get Invoice
let (invoice, quoteId) = try await coordinator.topUp(mint: mintURL, amount: 100)

// 2. Wait for Payment (Blocking or Polling)
try await coordinator.pollUntilPaid(mint: mintURL, quoteId: quoteId)

// 3. Receive Tokens (Auto-adds to wallet)
try await coordinator.receiveTokens(mint: mintURL, quoteId: quoteId, amount: 100)
```

# Supported NUTS
| NUT | Description | Status |
|---|---|---|
| **00** | Cryptography & Models | ✅ |
| **01** | Mint Public Keys | ✅ |
| **02** | Keysets | ✅ |
| **03** | Swap (Split) | ✅ |
| **04** | Mint Tokens | ✅ |
| **05** | Melt (Lightning Pay) | ✅ |
| **06** | Mint Info | ✅ |

# License
MIT License.

