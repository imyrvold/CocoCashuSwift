import Foundation

/// Pure, I/O-free proof bookkeeping shared by the in-memory and file-backed
/// repositories, so the two can't drift apart. Keyed by signature `C`, which
/// structurally dedupes proofs (the same signature can only exist once).
struct ProofStore {
    private(set) var byC: [String: Proof] = [:]

    init(_ proofs: [Proof] = []) {
        for p in proofs { byC[p.C] = p }
    }

    private static func sameMint(_ a: URL, _ b: URL) -> Bool {
        a.absoluteString.trimmingCharacters(in: .init(charactersIn: "/"))
            == b.absoluteString.trimmingCharacters(in: .init(charactersIn: "/"))
    }

    mutating func insert(_ proof: Proof) {
        byC[proof.C] = proof
    }

    mutating func insertMany(_ proofs: [Proof]) {
        for p in proofs {
            if var existing = byC[p.C] {
                // Existing proof: refresh metadata and revive if newly seen as
                // unspent (e.g. a restore scan finding a proof we'd marked spent).
                existing.mint = p.mint
                existing.keysetId = p.keysetId
                if existing.state != .unspent && p.state == .unspent {
                    existing.state = .unspent
                }
                byC[p.C] = existing
            } else {
                byC[p.C] = p
            }
        }
    }

    /// Release reservations whose timeout has passed (the operation that reserved
    /// them died without cleaning up). `.pending` proofs are never touched — they
    /// were knowingly submitted to the mint and only NUT-07 may resolve them.
    /// Returns whether anything changed (so a caller can persist only when needed).
    @discardableResult
    mutating func releaseExpired(now: Date) -> Bool {
        var changed = false
        for (key, proof) in byC where proof.state == .reserved {
            if let until = proof.reservedUntil, until < now {
                var p = proof
                p.state = .unspent
                p.reservedUntil = nil
                byC[key] = p
                changed = true
            }
        }
        return changed
    }

    func proofs(state: ProofState, mint: MintURL?) -> [Proof] {
        byC.values.filter { p in
            p.state == state && (mint == nil || Self.sameMint(p.mint, mint!))
        }
    }

    mutating func updateState(ids: [ProofId], to state: ProofState) {
        let idSet = Set(ids)
        for (key, proof) in byC where idSet.contains(proof.id) {
            var p = proof
            p.state = state
            byC[key] = p
        }
    }

    mutating func reserve(ids: [ProofId], until: Date) {
        let idSet = Set(ids)
        for (key, proof) in byC where idSet.contains(proof.id) {
            var p = proof
            p.reservedUntil = until
            p.state = .reserved
            byC[key] = p
        }
    }

    mutating func delete(ids: [ProofId]) {
        let idSet = Set(ids)
        for (key, proof) in byC where idSet.contains(proof.id) {
            byC.removeValue(forKey: key)
        }
    }

    /// Proofs worth persisting: everything except spent. Spent proofs are only
    /// needed in-session for dedupe/revive; persisting them would grow the file
    /// without bound.
    var persistable: [Proof] {
        byC.values.filter { $0.state != .spent }
    }
}
