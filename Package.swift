// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CocoCashuSwift",
  platforms: [
    .iOS(.v17), .macOS(.v14)
  ],
  products: [
    .library(name: "CocoCashuCore", targets: ["CocoCashuCore"]),
    .library(name: "CocoCashuUI", targets: ["CocoCashuUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/GigaBitcoin/secp256k1.swift", exact: "0.2.0"),
    // Pinned: SeedManager uses the 1.0.1 Mnemonic API (non-throwing init, `seed: [UInt8]`).
    // 1.0.2 changed that API, so allowing it to float breaks the build.
    .package(url: "https://github.com/pengpengliu/BIP39", exact: "1.0.1")
  ],
  targets: [
    .target(
      name: "CocoCashuCore",
      dependencies: [
        .product(name: "secp256k1", package: "secp256k1.swift"),
        .product(name: "BIP39", package: "BIP39")
      ]
    ),
    .target(name: "CocoCashuUI", dependencies: ["CocoCashuCore"]),
    .testTarget(name: "CocoCashuCoreTests", dependencies: ["CocoCashuCore"]),
  ]
)

