import XCTest
import CryptoKit
import BIP39
@testable import CocoCashuCore

final class CocoCashuCoreTests: XCTestCase {
  func testInsertProof() async throws {
    let repo = InMemoryProofRepository()
    let proof = Proof(amount: 100, mint: URL(string:"https://mint.test")!, secret: Data(), C: "02abc", keysetId: "009a1f293253e41e")
    try await repo.insert(proof)
    let fetched = try await repo.fetchUnspent(mint: nil)
    XCTAssertEqual(fetched.count, 1)
  }

  // MARK: - FileProofRepository persistence

  private func tempProofURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("coco-proofs-\(UUID().uuidString).json")
  }

  private func makeProof(_ amount: Int64, c: String, state: ProofState = .unspent) -> Proof {
    Proof(amount: amount, mint: URL(string: "https://mint.test")!,
          secret: Data("secret-\(c)".utf8), C: c, keysetId: "009a1f293253e41e", state: state)
  }

  /// Proofs must survive a repository re-open (the balance the wallet relaunches to).
  func testFileProofRepoRoundTripsAcrossReopen() async throws {
    let url = tempProofURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let repo = FileProofRepository(url: url)
    try await repo.insertMany([makeProof(8, c: "02aa"), makeProof(2, c: "02bb")])

    let reopened = FileProofRepository(url: url)
    let unspent = try await reopened.fetchUnspent(mint: nil)
    XCTAssertEqual(unspent.map(\.amount).reduce(0, +), 10)
    XCTAssertEqual(Set(unspent.map(\.C)), ["02aa", "02bb"])
  }

  /// Spent proofs are dropped on persist (bounds file growth); pending survive.
  func testFileProofRepoPersistsPendingButNotSpent() async throws {
    let url = tempProofURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let repo = FileProofRepository(url: url)
    let spent = makeProof(4, c: "02cc")
    let pending = makeProof(1, c: "02dd")
    try await repo.insert(spent)
    try await repo.insert(pending)
    try await repo.updateState(ids: [spent.id], to: .spent)
    try await repo.updateState(ids: [pending.id], to: .pending)

    let reopened = FileProofRepository(url: url)
    let allPending = try await reopened.fetchPending(mint: nil)
    XCTAssertEqual(allPending.map(\.C), ["02dd"], "pending must persist")
    // Spent proof must be gone entirely (not persisted).
    let unspent = try await reopened.fetchUnspent(mint: nil)
    XCTAssertTrue(unspent.isEmpty)
  }

  /// A reserved proof from a killed session reloads as pending, so launch
  /// reconciliation resolves it instead of it looking spendable.
  func testFileProofRepoReloadsReservedAsPending() async throws {
    let url = tempProofURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let repo = FileProofRepository(url: url)
    let p = makeProof(16, c: "02ee")
    try await repo.insert(p)
    try await repo.reserve(ids: [p.id], until: Date().addingTimeInterval(300))

    let reopened = FileProofRepository(url: url)
    let unspent = try await reopened.fetchUnspent(mint: nil)
    let pending = try await reopened.fetchPending(mint: nil)
    XCTAssertTrue(unspent.isEmpty, "reserved must not reload as spendable")
    XCTAssertEqual(pending.map(\.C), ["02ee"], "reserved reloads as pending")
  }

  /// Existing wallets wrote a legacy StoredProof file; the repo must migrate it
  /// so balances aren't lost on upgrade.
  func testFileProofRepoMigratesLegacyFormat() async throws {
    let url = tempProofURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let legacy = """
    [{"amount":21,"mint":"https://mint.test","secretBase64":"\(Data("legacy-secret".utf8).base64EncodedString())","C":"02ff","keysetId":"009a1f293253e41e","state":"unspent"}]
    """
    try Data(legacy.utf8).write(to: url)

    let repo = FileProofRepository(url: url)
    let unspent = try await repo.fetchUnspent(mint: nil)
    XCTAssertEqual(unspent.count, 1)
    XCTAssertEqual(unspent.first?.amount, 21)
    XCTAssertEqual(unspent.first?.C, "02ff")
    XCTAssertEqual(unspent.first?.secret, Data("legacy-secret".utf8))
  }

  // MARK: - WalletStorage layout & resets

  /// The reset semantics are security-relevant: a full reset must remove every
  /// wallet file (history leaks activity), while an imported-seed reset must
  /// keep the mint registry (mints aren't seed-specific — the post-import scan
  /// needs them) but remove everything derived from the old seed.
  func testWalletStorageResetSemantics() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("coco-storage-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let storage = WalletStorage(directory: dir)
    let fm = FileManager.default
    for url in [storage.proofsURL, storage.countersURL, storage.historyURL, storage.mintsURL] {
      try Data("[]".utf8).write(to: url)
    }

    storage.clearBalance()
    XCTAssertFalse(fm.fileExists(atPath: storage.proofsURL.path), "clearBalance removes proofs")
    XCTAssertTrue(fm.fileExists(atPath: storage.countersURL.path), "clearBalance keeps counters")

    try Data("[]".utf8).write(to: storage.proofsURL)
    storage.resetForImportedSeed()
    XCTAssertFalse(fm.fileExists(atPath: storage.proofsURL.path))
    XCTAssertFalse(fm.fileExists(atPath: storage.countersURL.path))
    XCTAssertFalse(fm.fileExists(atPath: storage.historyURL.path))
    XCTAssertTrue(fm.fileExists(atPath: storage.mintsURL.path), "import reset keeps the mint registry")

    try Data("[]".utf8).write(to: storage.proofsURL)
    storage.resetForNewSeed()
    XCTAssertFalse(fm.fileExists(atPath: storage.mintsURL.path), "full reset removes the mint registry too")
  }

  // MARK: - Multi-mint selection & registry

  /// A token/melt spends from ONE mint: pick the largest balance that covers
  /// the amount, or nothing when no single mint suffices (even if the total does).
  func testMintSelectionPicksSingleCoveringMint() {
    let a = URL(string: "https://cashu.cz")!
    let b = URL(string: "https://mint.minibits.cash/Bitcoin")!
    let balances = [(mint: a, balance: Int64(52)), (mint: b, balance: Int64(13))]

    XCTAssertEqual(MintSelection.pick(covering: 13, from: balances), a, "largest covering balance wins")
    XCTAssertEqual(MintSelection.pick(covering: 52, from: balances), a)
    XCTAssertNil(MintSelection.pick(covering: 60, from: balances), "total (65) covers it but no single mint does")
    XCTAssertNil(MintSelection.pick(covering: 1, from: []))
  }

  /// Mint identity ignores trailing slashes and case so the same mint written
  /// two ways doesn't get scanned or counted twice.
  func testMintDedupeNormalizesURLs() {
    let urls = [
      URL(string: "https://cashu.cz")!,
      URL(string: "https://cashu.cz/")!,
      URL(string: "https://CASHU.cz")!,
      URL(string: "https://mint.minibits.cash/Bitcoin")!,
    ]
    XCTAssertEqual(MintSelection.dedupe(urls).count, 2)
  }

  /// The mint registry must survive a reopen (that's its whole purpose).
  func testFileMintRepositoryRoundTrips() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("coco-mints-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let repo = FileMintRepository(url: url)
    try await repo.upsert(Mint(base: URL(string: "https://cashu.cz")!))
    try await repo.upsert(Mint(base: URL(string: "https://mint.minibits.cash/Bitcoin")!))

    let reopened = FileMintRepository(url: url)
    let mints = try await reopened.fetchAll()
    XCTAssertEqual(Set(mints.map(\.base.absoluteString)),
                   ["https://cashu.cz", "https://mint.minibits.cash/Bitcoin"])
  }

  // MARK: - BOLT11 amount decoding

  /// The invoice-amount preview must be exact whole sats or nil — never rounded.
  func testBOLT11AmountDecoding() {
    // Real shapes from live testing: 440n = 44 sats, 240n = 24 sats.
    XCTAssertEqual(BOLT11.amountSats(from: "lnbc440n1p49hqy3pp5zf45ruwfpt"), 44)
    XCTAssertEqual(BOLT11.amountSats(from: "lnbc240n1pfoo"), 24)
    // Each multiplier.
    XCTAssertEqual(BOLT11.amountSats(from: "lnbc1m1pfoo"), 100_000)
    XCTAssertEqual(BOLT11.amountSats(from: "lnbc26u1pfoo"), 2_600)
    XCTAssertEqual(BOLT11.amountSats(from: "lnbc10n1pfoo"), 1)
    XCTAssertEqual(BOLT11.amountSats(from: "lnbc10000p1pfoo"), 1)
    // Testnet prefix.
    XCTAssertEqual(BOLT11.amountSats(from: "lntb440n1pfoo"), 44)
    // Fractional sats must be REJECTED, not truncated (10.5 sats ≠ 10).
    XCTAssertNil(BOLT11.amountSats(from: "lnbc105n1pfoo"))
    XCTAssertNil(BOLT11.amountSats(from: "lnbc12345p1pfoo"))
    // Amountless invoice: `lnbc1<data>` — data starting with a multiplier letter
    // must not be misread as an amount (the '1' here is the bech32 separator).
    XCTAssertNil(BOLT11.amountSats(from: "lnbc1m5qxpqysgqcashu"))
    XCTAssertNil(BOLT11.amountSats(from: "lnbc1p49hqy3ppfoo"))
    // Non-invoices.
    XCTAssertNil(BOLT11.amountSats(from: "cashuBpGF0"))
    XCTAssertNil(BOLT11.amountSats(from: ""))
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

  /// The NUT-07 checkstate request identifies proofs by Y = hash_to_curve(secret);
  /// `cashu_Y_hex` must reproduce the same NUT-00 vectors as the engine's method
  /// (it is the same shared implementation — this pins the delegation).
  func testProofYComputationMatchesNUT00Vectors() throws {
    let zero = Data(repeating: 0, count: 32)
    XCTAssertEqual(try cashu_Y_hex(secret: zero),
                   "024cce997d3b518f739663b757deaec95bcd9473c30a14ac2fd04023a739d1a725")
  }

  // MARK: - NUT-12 DLEQ verification

  /// Official NUT-12 "BlindSignature Verification" test vector. If this fails the
  /// alice-side DLEQ math (R1 = s·G − e·A, R2 = s·B_ − e·C_, e == hash_e(...)) is
  /// wrong, and every mint/swap would reject valid signatures once DLEQ is enforced.
  func testDLEQVerifiesOfficialNUT12BlindSignatureVector() async throws {
    let engine = makeEngine(counter: InMemoryCounterRepository())
    let A  = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    let B_ = "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2"
    let C_ = "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2"
    let e  = "9818e061ee51d5c8edc3342369a554998ff7b4381c8652d724cdf46429be73d9"
    let s  = "9818e061ee51d5c8edc3342369a554998ff7b4381c8652d724cdf46429be73da"

    let ok = await engine.verifyDLEQ(blindedMessage: B_, blindSignature: C_, mintPubKey: A, e: e, s: s)
    XCTAssertTrue(ok, "Official NUT-12 BlindSignature DLEQ vector must verify")

    // A tampered `s` (here reusing the `e` value) must be rejected.
    let bad = await engine.verifyDLEQ(blindedMessage: B_, blindSignature: C_, mintPubKey: A, e: e, s: e)
    XCTAssertFalse(bad, "A DLEQ proof with the wrong s must be rejected")
  }

  // MARK: - NUT-13 official derivation vectors

  private static let nut13Mnemonic = "half depart obvious quality work element tank gorilla view sugar picture humble"

  private func makeVectorEngine(keysetID: String) throws -> CocoBlindingEngine {
    let mnemonic = try BIP39.Mnemonic(phrase: Self.nut13Mnemonic.components(separatedBy: " "))
    let seed = Data(mnemonic.seed)
    let keyset = Keyset(id: keysetID, keys: [1: "02aa"])
    return CocoBlindingEngine(seed: seed, counterRepo: InMemoryCounterRepository()) { _ in keyset }
  }

  /// Official NUT-13 test vectors, version 00 keyset (BIP32 derivation). If this
  /// fails, seed phrases are not portable: funds minted here can't be restored in
  /// any other Cashu wallet and vice versa.
  func testNUT13Version00DerivationMatchesOfficialVectors() async throws {
    let keysetID = "009a1f293253e41e"
    let engine = try makeVectorEngine(keysetID: keysetID)
    let mint = URL(string: "https://mint.test")!

    let expectedSecrets = [
      "485875df74771877439ac06339e284c3acfcd9be7abf3bc20b516faeadfe77ae",
      "8f2b39e8e594a4056eb1e6dbb4b0c38ef13b1b2c751f64f810ec04ee35b77270",
      "bc628c79accd2364fd31511216a0fab62afd4a18ff77a20deded7b858c9860c8",
      "59284fd1650ea9fa17db2b3acf59ecd0f2d52ec3261dd4152785813ff27a33bf",
      "576c23393a8b31cc8da6688d9c9a96394ec74b40fdaf1f693a6bb84284334ea0",
    ]
    let expectedRs = [
      "ad00d431add9c673e843d4c2bf9a778a5f402b985b8da2d5550bf39cda41d679",
      "967d5232515e10b81ff226ecf5a9e2e2aff92d66ebc3edf0987eb56357fd6248",
      "b20f47bb6ae083659f3aa986bfa0435c55c6d93f687d51a01f26862d9b9a4899",
      "fb5fca398eb0b1deb955a2988b5ac77d32956155f1c002a373535211a2dfdc29",
      "5f09bfbfe27c439a597719321e061e2e40aad4a36768bb2bcc3de547c9644bf9",
    ]

    let (_, secrets) = try await engine.deriveForRestore(
      indices: [0, 1, 2, 3, 4], mint: mint, keysetID: keysetID
    )
    for i in 0..<5 {
      let (secret, r) = try XCTUnwrap(secrets[UInt32(i)])
      XCTAssertEqual(String(data: secret, encoding: .utf8), expectedSecrets[i], "secret at counter \(i)")
      XCTAssertEqual(hex(r), expectedRs[i], "r at counter \(i)")
    }
  }

  /// Official NUT-13 test vectors, version 01 keyset (HMAC-SHA256 KDF).
  func testNUT13Version01DerivationMatchesOfficialVectors() async throws {
    let keysetID = "015ba18a8adcd02e715a58358eb618da4a4b3791151a4bee5e968bb88406ccf76a"
    let engine = try makeVectorEngine(keysetID: keysetID)
    let mint = URL(string: "https://mint.test")!

    let expectedSecrets = [
      "db5561a07a6e6490f8dadeef5be4e92f7cebaecf2f245356b5b2a4ec40687298",
      "b70e7b10683da3bf1cdf0411206f8180c463faa16014663f39f2529b2fda922e",
      "78a7ac32ccecc6b83311c6081b89d84bb4128f5a0d0c5e1af081f301c7a513f5",
      "094a2b6c63bfa7970bc09cda0e1cfc9cd3d7c619b8e98fabcfc60aea9e4963e5",
      "5e89fc5d30d0bf307ddf0a3ac34aa7a8ee3702169dafa3d3fe1d0cae70ecd5ef",
    ]
    let expectedRs = [
      "6d26181a3695e32e9f88b80f039ba1ae2ab5a200ad4ce9dbc72c6d3769f2b035",
      "bde4354cee75545bea1a2eee035a34f2d524cee2bb01613823636e998386952e",
      "f40cc1218f085b395c8e1e5aaa25dccc851be3c6c7526a0f4e57108f12d6dac4",
      "099ed70fc2f7ac769bc20b2a75cb662e80779827b7cc358981318643030577d0",
      "5550337312d223ba62e3f75cfe2ab70477b046d98e3e71804eade3956c7b98cf",
    ]

    let (_, secrets) = try await engine.deriveForRestore(
      indices: [0, 1, 2, 3, 4], mint: mint, keysetID: keysetID
    )
    for i in 0..<5 {
      let (secret, r) = try XCTUnwrap(secrets[UInt32(i)])
      XCTAssertEqual(String(data: secret, encoding: .utf8), expectedSecrets[i], "secret at counter \(i)")
      XCTAssertEqual(hex(r), expectedRs[i], "r at counter \(i)")
    }
  }

  // MARK: - NUT-02 keyset ID integrity

  /// A keyset whose claimed v00 ID doesn't match its keys must be rejected;
  /// the derived ID must be stable and correctly formatted.
  func testKeysetV00IdDerivationAndValidation() throws {
    // Two deterministic (valid-format) compressed pubkeys.
    let rawKeys: [String: String] = [
      "1": "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
      "2": "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2",
    ]
    let derived = try XCTUnwrap(Keyset.deriveV00Id(rawKeys: rawKeys))
    XCTAssertTrue(derived.hasPrefix("00"))
    XCTAssertEqual(derived.count, 16)

    // Self-consistent keyset validates; a lying ID of valid v00 shape does not.
    XCTAssertTrue(Keyset.isValidV00Id(derived, rawKeys: rawKeys))
    XCTAssertFalse(Keyset.isValidV00Id("00deadbeefdead00", rawKeys: rawKeys))
    // Non-v00 ids are (for now) not checkable and must not be rejected.
    XCTAssertTrue(Keyset.isValidV00Id("015ba18a8adcd02e715a58358eb618da4a4b3791151a4bee5e968bb88406ccf76a", rawKeys: rawKeys))
  }

  /// Regression: mints publish 64 denominations up to 2^63 (9223372036854775808),
  /// which does NOT fit in Int64. Deriving the ID from the Int64-parsed map
  /// silently dropped that key and mis-derived the ID, wrongly rejecting every
  /// honest 64-key mint (hit in the field against mint.minibits.cash). The raw
  /// derivation must include it. (Expected value independently computed with
  /// python hashlib over the same keys.)
  func testKeysetV00IdIncludesAmountsBeyondInt64() throws {
    let rawKeys: [String: String] = [
      "1": "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798",
      "9223372036854775808": "02a9acc1e48c25eeeb9289b5031cc57da9fe72f3fe2861d264bdc074209b107ba2",
    ]
    XCTAssertEqual(Keyset.deriveV00Id(rawKeys: rawKeys), "00e7ce2799825ee6")
    XCTAssertTrue(Keyset.isValidV00Id("00e7ce2799825ee6", rawKeys: rawKeys))
  }

  // MARK: - NUT-00 V4 (cashuB) token deserialization

  /// Official NUT-00 V4 single-keyset test vector. Failing this means the wallet
  /// can't receive tokens from modern wallets (Minibits/cashu.me send cashuB).
  func testTokenV4DeserializesOfficialSingleKeysetVector() throws {
    let token = "cashuBpGF0gaJhaUgArSaMTR9YJmFwgaNhYQFhc3hAOWE2ZGJiODQ3YmQyMzJiYTc2ZGIwZGYxOTcyMTZiMjlkM2I4Y2MxNDU1M2NkMjc4MjdmYzFjYzk0MmZlZGI0ZWFjWCEDhhhUP_trhpXfStS6vN6So0qWvc2X3O4NfM-Y1HISZ5JhZGlUaGFuayB5b3VhbXVodHRwOi8vbG9jYWxob3N0OjMzMzhhdWNzYXQ="

    let decoded = try TokenV4Helper.deserialize(token)
    XCTAssertEqual(decoded.mint, "http://localhost:3338")
    XCTAssertEqual(decoded.unit, "sat")
    XCTAssertEqual(decoded.memo, "Thank you")
    XCTAssertEqual(decoded.proofs.count, 1)

    let p = try XCTUnwrap(decoded.proofs.first)
    XCTAssertEqual(p.keysetId, "00ad268c4d1f5826")
    XCTAssertEqual(p.amount, 1)
    XCTAssertEqual(p.secret, "9a6dbb847bd232ba76db0df197216b29d3b8cc14553cd27827fc1cc942fedb4e")
    XCTAssertEqual(p.C, "038618543ffb6b8695df4ad4babcde92a34a96bdcd97dcee0d7ccf98d472126792")
  }

  /// Official NUT-00 V4 multi-keyset test vector (2 keysets, 3 proofs).
  func testTokenV4DeserializesOfficialMultiKeysetVector() throws {
    let token = "cashuBo2F0gqJhaUgA_9SLj17PgGFwgaNhYQFhc3hAYWNjMTI0MzVlN2I4NDg0YzNjZjE4NTAxNDkyMThhZjkwZjcxNmE1MmJmNGE1ZWQzNDdlNDhlY2MxM2Y3NzM4OGFjWCECRFODGd5IXVW-07KaZCvuWHk3WrnnpiDhHki6SCQh88-iYWlIAK0mjE0fWCZhcIKjYWECYXN4QDEzMjNkM2Q0NzA3YTU4YWQyZTIzYWRhNGU5ZjFmNDlmNWE1YjRhYzdiNzA4ZWIwZDYxZjczOGY0ODMwN2U4ZWVhY1ghAjRWqhENhLSsdHrr2Cw7AFrKUL9Ffr1XN6RBT6w659lNo2FhAWFzeEA1NmJjYmNiYjdjYzY0MDZiM2ZhNWQ1N2QyMTc0ZjRlZmY4YjQ0MDJiMTc2OTI2ZDNhNTdkM2MzZGNiYjU5ZDU3YWNYIQJzEpxXGeWZN5qXSmJjY8MzxWyvwObQGr5G1YCCgHicY2FtdWh0dHA6Ly9sb2NhbGhvc3Q6MzMzOGF1Y3NhdA"

    let decoded = try TokenV4Helper.deserialize(token)
    XCTAssertEqual(decoded.mint, "http://localhost:3338")
    XCTAssertEqual(decoded.unit, "sat")
    XCTAssertNil(decoded.memo)
    XCTAssertEqual(decoded.proofs.count, 3)

    XCTAssertEqual(decoded.proofs[0].keysetId, "00ffd48b8f5ecf80")
    XCTAssertEqual(decoded.proofs[0].amount, 1)
    XCTAssertEqual(decoded.proofs[0].secret, "acc12435e7b8484c3cf1850149218af90f716a52bf4a5ed347e48ecc13f77388")
    XCTAssertEqual(decoded.proofs[0].C, "0244538319de485d55bed3b29a642bee5879375ab9e7a620e11e48ba482421f3cf")

    XCTAssertEqual(decoded.proofs[1].keysetId, "00ad268c4d1f5826")
    XCTAssertEqual(decoded.proofs[1].amount, 2)
    XCTAssertEqual(decoded.proofs[1].secret, "1323d3d4707a58ad2e23ada4e9f1f49f5a5b4ac7b708eb0d61f738f48307e8ee")
    XCTAssertEqual(decoded.proofs[1].C, "023456aa110d84b4ac747aebd82c3b005aca50bf457ebd5737a4414fac3ae7d94d")

    XCTAssertEqual(decoded.proofs[2].keysetId, "00ad268c4d1f5826")
    XCTAssertEqual(decoded.proofs[2].amount, 1)
    XCTAssertEqual(decoded.proofs[2].secret, "56bcbcbb7cc6406b3fa5d57d2174f4eff8b4402b176926d3a57d3c3dcbb59d57")
    XCTAssertEqual(decoded.proofs[2].C, "0273129c5719e599379a974a626363c333c56cafc0e6d01abe46d5808280789c63")
  }

  /// Malformed cashuB input must throw, not crash: truncated CBOR, garbage
  /// base64, wrong shape, and (importantly) a V3 JSON payload behind a cashuB prefix.
  func testTokenV4RejectsMalformedInput() {
    let bad = [
      "cashuB",                                       // empty payload
      "cashuB!!!!",                                   // invalid base64
      "cashuBAAAA",                                   // valid base64, garbage CBOR
      "cashuBpGF0gaJhaUgArSaMTR9YJmFwga",             // truncated vector
      "cashuBeyJ0b2tlbiI6W119",                       // JSON payload with B prefix
    ]
    for token in bad {
      XCTAssertThrowsError(try TokenV4Helper.deserialize(token), "must reject: \(token)")
    }
  }

  /// Restore must skip keysets NUT-13 can't derive on (legacy base64 IDs that
  /// mints still list, e.g. 'ctv28hTYzQwr' on mint.minibits.cash) instead of
  /// failing the whole mint scan on them — and must scan the supported formats.
  func testRestoreKeysetSupportGate() {
    XCTAssertTrue(WalletRestorationService.supportsNUT13Derivation(keysetId: "009a1f293253e41e"))
    XCTAssertTrue(WalletRestorationService.supportsNUT13Derivation(keysetId: "00107937db0cc865"))
    XCTAssertTrue(WalletRestorationService.supportsNUT13Derivation(keysetId: "015ba18a8adcd02e715a58358eb618da4a4b3791151a4bee5e968bb88406ccf76a"))
    XCTAssertFalse(WalletRestorationService.supportsNUT13Derivation(keysetId: "ctv28hTYzQwr"))     // legacy base64
    XCTAssertFalse(WalletRestorationService.supportsNUT13Derivation(keysetId: "0z12"))             // not hex
    XCTAssertFalse(WalletRestorationService.supportsNUT13Derivation(keysetId: "02deadbeef"))       // wrong version/length
    XCTAssertFalse(WalletRestorationService.supportsNUT13Derivation(keysetId: "https://mint.test"))
  }

  /// H6: unparseable keyset IDs must throw, never silently derive from branch 0.
  func testDerivationThrowsOnUnsupportedKeysetIDs() async throws {
    let engine = makeEngine(counter: InMemoryCounterRepository())
    let mint = URL(string: "https://mint.test")!

    for badId in ["https://mint.test", "notHex==", "0z12", "02deadbeef"] {
      do {
        _ = try await engine.deriveForRestore(indices: [0], mint: mint, keysetID: badId)
        XCTFail("Keyset ID '\(badId)' must be rejected, not silently mapped to branch 0")
      } catch { /* expected */ }
    }
  }
}
