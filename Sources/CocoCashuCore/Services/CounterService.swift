// CounterService.swift
import Foundation

public actor CounterService {
  private let counters: CounterRepository
  public init(counters: CounterRepository) { self.counters = counters }
  public func nextCounter(scope: String) async throws -> Int64 {
    try await counters.nextCounter(key: scope)
  }
}
