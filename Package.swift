// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "CocoCashuSwift",
  platforms: [
    .iOS(.v17), .macOS(.v14)
  ],
  products: [
    .library(name: "CocoCashuCore", targets: ["CocoCashuCore"]),
    .library(name: "CocoCashuSQLite", targets: ["CocoCashuSQLite"]),
    .library(name: "CocoCashuUI", targets: ["CocoCashuUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/GigaBitcoin/secp256k1.swift", exact: "0.2.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.27.0")
  ],
  targets: [
    .target(
      name: "CocoCashuCore",
      dependencies: [
        .product(name: "secp256k1", package: "secp256k1.swift")
      ]
    ),
    .target(name: "CocoCashuSQLite", dependencies: [
      "CocoCashuCore", .product(name: "GRDB", package: "GRDB.swift")
    ]),
    .target(name: "CocoCashuUI", dependencies: ["CocoCashuCore"]),
    .testTarget(name: "CocoCashuCoreTests", dependencies: ["CocoCashuCore"]),
//    .testTarget(
//      name: "CocoCashuSQLiteTests",
//      dependencies: ["CocoCashuSQLite"]
//    )
  ]
)
