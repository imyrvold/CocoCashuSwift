// SQLiteRepositories.swift
import Foundation
import GRDB
import CocoCashuCore

// MARK: - Record types
struct ProofRecord: Codable, FetchableRecord, PersistableRecord {
  var id: String
  var amount: Int64
  var mint: String
  var secret: Data
  var state: String
  var createdAt: Date
  var reservedUntil: Date?
}

struct MintRecord: Codable, FetchableRecord, PersistableRecord {
  var base: String
  var name: String?
  var pubkey: Data?
}

struct QuoteRecord: Codable, FetchableRecord, PersistableRecord {
  var id: String
  var mint: String
  var amount: Int64
  var createdAt: Date
  var status: String
  var invoice: String?
  var preimage: String?
  var expiresAt: Date?
}

// MARK: - Database + migrations
public final class CashuDatabase {
  public let dbQueue: DatabaseQueue
  public init(path: String) throws {
    dbQueue = try DatabaseQueue(path: path)
    try migrator.migrate(dbQueue)
  }

  private var migrator: DatabaseMigrator {
    var m = DatabaseMigrator()
    m.registerMigration("v1") { db in
      try db.create(table: "proofs") { t in
        t.column("id", .text).primaryKey()
        t.column("amount", .integer).notNull()
        t.column("mint", .text).notNull().indexed()
        t.column("secret", .blob).notNull()
        t.column("state", .text).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("reservedUntil", .datetime)
      }
      try db.create(table: "mints") { t in
        t.column("base", .text).primaryKey()
        t.column("name", .text)
        t.column("pubkey", .blob)
      }
      try db.create(table: "quotes") { t in
        t.column("id", .text).primaryKey()
        t.column("mint", .text).notNull().indexed()
        t.column("amount", .integer).notNull()
        t.column("createdAt", .datetime).notNull()
        t.column("status", .text).notNull()
        t.column("invoice", .text)
        t.column("preimage", .text)
        t.column("expiresAt", .datetime)
      }
      try db.create(table: "counters") { t in
        t.column("key", .text).primaryKey()
        t.column("value", .integer).notNull()
      }
    }
    return m
  }
}

// MARK: - Repositories
public actor SQLiteProofRepository: ProofRepository {
  let db: CashuDatabase
  public init(db: CashuDatabase) { self.db = db }

  public func insert(_ proof: Proof) async throws {
    try await db.dbQueue.write { db in
      let r = ProofRecord(
        id: proof.id.uuidString, amount: proof.amount,
        mint: proof.mint.absoluteString, secret: proof.secret,
        state: proof.state.rawValue, createdAt: proof.createdAt,
        reservedUntil: proof.reservedUntil
      )
      try r.insert(db)
    }
  }

  public func insertMany(_ proofs: [Proof]) async throws {
    try await db.dbQueue.write { db in
      for proof in proofs {
        let r = ProofRecord(
          id: proof.id.uuidString, amount: proof.amount,
          mint: proof.mint.absoluteString, secret: proof.secret,
          state: proof.state.rawValue, createdAt: proof.createdAt,
          reservedUntil: proof.reservedUntil
        )
        try r.insert(db)
      }
    }
  }

  public func fetchUnspent(mint: MintURL?) async throws -> [Proof] {
    try await db.dbQueue.read { db in
      let sql = mint == nil
        ? "SELECT * FROM proofs WHERE state = 'unspent'"
        : "SELECT * FROM proofs WHERE state = 'unspent' AND mint = ?"
      let rows = try ProofRecord.fetchAll(db, sql: sql, arguments: mint == nil ? [] : [mint!.absoluteString])
      return rows.map {
        Proof(
          id: UUID(uuidString: $0.id)!,
          amount: $0.amount,
          mint: URL(string: $0.mint)!,
          secret: $0.secret,
          state: ProofState(rawValue: $0.state) ?? .unspent,
          createdAt: $0.createdAt,
          reservedUntil: $0.reservedUntil
        )
      }
    }
  }

  public func updateState(ids: [ProofId], to state: ProofState) async throws {
    try await db.dbQueue.write { db in
      guard !ids.isEmpty else { return }
      let idStrings = ids.map(\.uuidString)
      let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ",")
      var args = StatementArguments()
      _ = args.append(contentsOf: [state.rawValue])
      _ = args.append(contentsOf: StatementArguments(idStrings))
      try db.execute(sql: """
        UPDATE proofs SET state = ? WHERE id IN (\(placeholders))
      """, arguments: args)
    }
  }

  public func reserve(ids: [ProofId], until: Date) async throws {
    try await db.dbQueue.write { db in
      guard !ids.isEmpty else { return }
      let idStrings = ids.map(\.uuidString)
      let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ",")
      var args = StatementArguments()
      _ = args.append(contentsOf: [until])
      _ = args.append(contentsOf: StatementArguments(idStrings))
      try db.execute(sql: """
        UPDATE proofs SET state = 'reserved', reservedUntil = ? WHERE id IN (\(placeholders))
      """, arguments: args)
    }
  }

  public func delete(ids: [ProofId]) async throws {
    try await db.dbQueue.write { db in
      guard !ids.isEmpty else { return }
      let idStrings = ids.map(\.uuidString)
      let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ",")
      var args = StatementArguments()
      _ = args.append(contentsOf: StatementArguments(idStrings))
      try db.execute(sql: "DELETE FROM proofs WHERE id IN (\(placeholders))", arguments: args)
    }
  }
}

public actor SQLiteMintRepository: MintRepository {
  let db: CashuDatabase
  public init(db: CashuDatabase) { self.db = db }

  public func upsert(_ mint: Mint) async throws {
    try await db.dbQueue.write { db in
      let r = MintRecord(base: mint.base.absoluteString, name: mint.name, pubkey: nil)
      try r.save(db)
    }
  }

  public func fetchAll() async throws -> [Mint] {
    try await db.dbQueue.read { db in
      try MintRecord.fetchAll(db).map {
        Mint(base: URL(string: $0.base)!, name: $0.name)
      }
    }
  }

  public func fetch(by url: MintURL) async throws -> Mint? {
    try await db.dbQueue.read { db in
      try MintRecord.fetchOne(db, key: url.absoluteString).map {
        Mint(base: URL(string: $0.base)!, name: $0.name)
      }
    }
  }
}

public actor SQLiteQuoteRepository: QuoteRepository {
  let db: CashuDatabase
  public init(db: CashuDatabase) { self.db = db }

  public func insert(_ q: Quote) async throws {
    try await db.dbQueue.write { db in
      let r = QuoteRecord(
        id: q.id.uuidString, mint: q.mint.absoluteString, amount: q.amount,
        createdAt: q.createdAt, status: q.status.rawValue,
        invoice: q.invoice, preimage: q.preimage, expiresAt: q.expiresAt
      )
      try r.insert(db)
    }
  }

  public func update(_ q: Quote) async throws {
    try await db.dbQueue.write { db in
      let r = QuoteRecord(
        id: q.id.uuidString, mint: q.mint.absoluteString, amount: q.amount,
        createdAt: q.createdAt, status: q.status.rawValue,
        invoice: q.invoice, preimage: q.preimage, expiresAt: q.expiresAt
      )
      try r.save(db)
    }
  }

  public func fetch(id: QuoteId) async throws -> Quote? {
    try await db.dbQueue.read { db in
      try QuoteRecord.fetchOne(db, key: id.uuidString).map {
        Quote(
          id: id, mint: URL(string: $0.mint)!, amount: $0.amount,
          createdAt: $0.createdAt,
          status: QuoteStatus(rawValue: $0.status) ?? .pending,
          invoice: $0.invoice, preimage: $0.preimage, expiresAt: $0.expiresAt
        )
      }
    }
  }

  public func fetchPending(mint: MintURL?) async throws -> [Quote] {
    try await db.dbQueue.read { db in
      let sql = mint == nil
        ? "SELECT * FROM quotes WHERE status = 'pending'"
        : "SELECT * FROM quotes WHERE status = 'pending' AND mint = ?"
      let rows: [QuoteRecord]
      if let mint {
        rows = try QuoteRecord.fetchAll(db, sql: sql, arguments: [mint.absoluteString])
      } else {
        rows = try QuoteRecord.fetchAll(db, sql: sql)
      }
      return rows.compactMap { r in
        guard let id = UUID(uuidString: r.id) else { return nil }
        return Quote(
          id: id, mint: URL(string: r.mint)!, amount: r.amount,
          createdAt: r.createdAt,
          status: .pending, invoice: r.invoice, preimage: r.preimage, expiresAt: r.expiresAt
        )
      }
    }
  }
}

public actor SQLiteCounterRepository: CounterRepository {
  let db: CashuDatabase
  public init(db: CashuDatabase) { self.db = db }

  public func nextCounter(key: String) async throws -> Int64 {
    try await db.dbQueue.write { db in
      if try Int64.fetchOne(db, sql: "SELECT value FROM counters WHERE key = ?", arguments: [key]) == nil {
        try db.execute(sql: "INSERT INTO counters(key, value) VALUES (?, 0)", arguments: [key])
      }
      try db.execute(sql: "UPDATE counters SET value = value + 1 WHERE key = ?", arguments: [key])
      return try Int64.fetchOne(db, sql: "SELECT value FROM counters WHERE key = ?", arguments: [key]) ?? 0
    }
  }
}

