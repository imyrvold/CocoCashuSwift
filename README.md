# CocoCashuSwift

A Swift port of the [coco-cashu](https://github.com/Egge21M/coco-cashu) library.  
This package provides a modular Cashu wallet core written in Swift.

## 📦 Structure

## 🚀 Getting Started

1. Clone or unzip this package:

   ```bash
   cd CocoCashuSwift
   
    2.    Build a local zip archive for Xcode:
    zip -r CocoCashuSwift.zip .
    
    3.    In Xcode, go to:
    File > Add Packages... > Add Local
    
Select your CocoCashuSwift.zip.

    4.    To run the demo app:
    •    Open CashuDemoApp/CashuDemoApp.xcodeproj
    •    Run on iOS Simulator or macOS

🧩 Features
    •    Core (CocoCashuCore)
    •    Strongly typed models: Proof, Mint, Quote, Token
    •    Storage-agnostic repositories
    •    Services: proof management, quote lifecycle
    •    Typed event bus (WalletEvent)
    •    UI (CocoCashuUI)
    •    ObservableWallet integrates with SwiftUI via @Observable
    •    Demo App
    •    Simple SwiftUI wallet
    •    In-memory repositories
    •    Buttons to mint fake sats and spend them

📸 Screenshot

Here’s how the demo looks when running:

--------------------------
 Cashu Demo Wallet
--------------------------
Mint: https://mint.test
Total: 100 sats
• 100 sats (unspent)

[ Mint 100 sats ]  [ Spend 50 sats ]

👉 After you run it in the iOS Simulator:
    •    Press ⌘ + S (or File > Save Screenshot) to capture a real image.
    •    Save it as CashuDemoApp/Screenshot.png.
    •    Then update the README to display it:
    
![Demo Screenshot](CashuDemoApp/Screenshot.png)

📝 Notes
    •    This demo does not implement full Cashu cryptography or HTTP API calls.
    •    InMemory*Repository is used for storage. Replace with SQLite or server-backed repos for persistence.
    •    Extend DemoAPI.swift with real mint endpoints to interact with live Cashu mints.

✅ Roadmap
    •    Add SQLite repo support (via GRDB)
    •    Implement real Cashu Mint API client
    •    Add proof splitting/merging logic
    •    Integrate Lightning invoices (BOLT11)

⸻

Made with ❤️ in Swift, inspired by coco-cashu.

