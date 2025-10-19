import XCTest
@testable import CocoCashuCore

final class CocoCashuCoreTests: XCTestCase {
  func testInsertProof() async throws {
    let repo = InMemoryProofRepository()
    let proof = Proof(amount: 100, mint: URL(string:"https://mint.test")!, secret: Data())
    try await repo.insert(proof)
    let fetched = try await repo.fetchUnspent(mint: nil)
    XCTAssertEqual(fetched.count, 1)
  }
}
