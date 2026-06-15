import XCTest
import CryptoKit
@testable import CocoCashuCore

final class CocoCashuCoreTests: XCTestCase {
  func testInsertProof() async throws {
    let repo = InMemoryProofRepository()
    let proof = Proof(amount: 100, mint: URL(string:"https://mint.test")!, secret: Data(), C: "02abc", keysetId: "009a1f293253e41e")
    try await repo.insert(proof)
    let fetched = try await repo.fetchUnspent(mint: nil)
    XCTAssertEqual(fetched.count, 1)
  }

  // MARK: - NUT-13 counter

  func testInMemoryCounterReservesFromZeroAndAdvances() async throws {
    let repo = InMemoryCounterRepository()
    let a = try await repo.reserve(key: "ks1", count: 3)
    let b = try await repo.reserve(key: "ks1", count: 2)
    XCTAssertEqual(a, 0, "First reservation must start at index 0")
    XCTAssertEqual(b, 3, "Second reservation must not overlap the first")
    let current = try await repo.current(key: "ks1")
    XCTAssertEqual(current, 5)
    // Independent scopes don't interfere.
    let other = try await repo.reserve(key: "ks2", count: 1)
    XCTAssertEqual(other, 0)
  }

  func testFileCounterPersistsAcrossInstancesWithoutOverlap() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("coco-counter-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let first = FileCounterRepository(url: url)
    let start1 = try await first.reserve(key: "ks", count: 4) // 0..3

    // Simulate an app restart: a brand new instance reading the same file.
    let second = FileCounterRepository(url: url)
    let start2 = try await second.reserve(key: "ks", count: 4) // must be 4..7

    XCTAssertEqual(start1, 0)
    XCTAssertEqual(start2, 4, "Counter must survive restart and never reuse indices")
  }

  // MARK: - Determinism: mint must match restore

  private func makeEngine(counter: CounterRepository) -> CocoBlindingEngine {
    // 32-byte deterministic test seed.
    let seed = Data((0..<32).map { UInt8($0) })
    let keyset = Keyset(id: "009a1f293253e41e", keys: [1: "02aa", 2: "03bb"])
    return CocoBlindingEngine(seed: seed, counterRepo: counter) { _ in keyset }
  }

  /// The whole point of NUT-13: a proof minted at index N must produce the exact
  /// same blinded message + secret that restore derives for index N.
  func testBlindMatchesRestoreDerivation() async throws {
    let engine = makeEngine(counter: InMemoryCounterRepository())
    let mint = URL(string: "https://mint.test")!

    let outs = try await engine.blind(parts: [1, 2], mint: mint) // indices 0, 1
    let (restoreOuts, secrets) = try await engine.deriveForRestore(
      indices: [0, 1], mint: mint, keysetID: "009a1f293253e41e"
    )

    XCTAssertEqual(outs.count, 2)
    XCTAssertEqual(restoreOuts.count, 2)
    // Index 0
    XCTAssertEqual(outs[0].B_, restoreOuts[0].B_, "Blinded message at index 0 must match restore")
    XCTAssertEqual(outs[0].secret, secrets[0]?.0, "Secret at index 0 must match restore")
    // Index 1
    XCTAssertEqual(outs[1].B_, restoreOuts[1].B_, "Blinded message at index 1 must match restore")
    XCTAssertEqual(outs[1].secret, secrets[1]?.0, "Secret at index 1 must match restore")
  }

  /// Successive blinds must consume fresh indices, never reusing a secret.
  func testBlindAdvancesCounter() async throws {
    let engine = makeEngine(counter: InMemoryCounterRepository())
    let mint = URL(string: "https://mint.test")!

    let first = try await engine.blind(parts: [1], mint: mint)  // index 0
    let second = try await engine.blind(parts: [1], mint: mint) // index 1

    XCTAssertNotEqual(first[0].B_, second[0].B_, "Reused index would reuse a secret — must differ")
  }

  // MARK: - Hash-to-curve correctness (NUT-00)

  private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

  /// The production engine's hash-to-curve MUST reproduce the official NUT-00 test
  /// vectors, otherwise proofs never verify at a real mint (the cause of melt 10001).
  func testEngineHashToCurveMatchesNUT00Vectors() async throws {
    let engine = makeEngine(counter: InMemoryCounterRepository())

    let zero = Data(repeating: 0, count: 32)
    var one = Data(repeating: 0, count: 31); one.append(0x01)
    var two = Data(repeating: 0, count: 31); two.append(0x02)

    var y0 = try await engine.hash_to_curve(zero)
    var y1 = try await engine.hash_to_curve(one)
    var y2 = try await engine.hash_to_curve(two)

    XCTAssertEqual(hex(try ec_serialize_pubkey(&y0)), "024cce997d3b518f739663b757deaec95bcd9473c30a14ac2fd04023a739d1a725")
    XCTAssertEqual(hex(try ec_serialize_pubkey(&y1)), "022e7158e11c9506f1aa4248bf531298daa7febd6194f003edcd9b93ade6253acf")
    XCTAssertEqual(hex(try ec_serialize_pubkey(&y2)), "026cdbe15362df59cd1dd3c9c11de8aedac2106eca69236ecd9fbe117af897be4f")
  }
}
