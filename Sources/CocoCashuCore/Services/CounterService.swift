// CounterService.swift
import Foundation

public actor CounterService {
  private let counters: CounterRepository
  public init(counters: CounterRepository) { self.counters = counters }
  /// The next unused index for a scope.
  public func current(scope: String) async throws -> Int64 {
    try await counters.current(key: scope)
  }
  /// Reserve `count` consecutive indices, returning the first.
  public func reserve(scope: String, count: Int) async throws -> Int64 {
    try await counters.reserve(key: scope, count: count)
  }
}
